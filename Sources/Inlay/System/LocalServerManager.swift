import Foundation
import Combine
import InlayCore
import Network
import Security

/// Installs and supervises the bundled server as a per-user LaunchAgent.
/// Ownership is decided by the marker file alone: an existing server on
/// 127.0.0.1:8391 without our marker is never adopted, probed for writes,
/// or stopped — the user connects to it manually instead.
@MainActor
final class LocalServerManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    enum ManagerError: LocalizedError {
        case noBundledServer
        case modelsMissing
        case portInUse
        case notOwned
        case launchctlFailed(String)
        case healthTimeout

        var errorDescription: String? {
            switch self {
            case .noBundledServer: "This build has no bundled server. Connect to your existing server below."
            case .modelsMissing: "Download both models first."
            case .portInUse: "Another server already uses port 8391. Connect to it below, or stop it and try again."
            case .notOwned: "This server was not installed by Inlay, so Inlay will not remove it."
            case .launchctlFailed(let detail): "The background service could not start: \(detail)"
            case .healthTimeout: "The server did not answer within 10 seconds. Its log is in the Logs folder."
            }
        }
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var portOccupiedByOther = false

    private let paths = LocalServerPaths.self
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        session = URLSession(configuration: configuration)
    }

    func detect() async {
        // A view appearing mid-install must not reset the claimed state and
        // re-enable the install button underneath the running attempt.
        if case .installing = state { return }
        if paths.installedMarkerExists {
            state = .installed
            portOccupiedByOther = false
            return
        }
        state = .notInstalled
        portOccupiedByOther = await Self.portIsListening(8391)
    }

    static func portIsListening(_ port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                          using: .tcp)
            let queue = DispatchQueue(label: "dev.davis.inlay.port-probe")
            var resumed = false
            connection.stateUpdateHandler = { state in
                let listening: Bool?
                switch state {
                case .ready: listening = true
                case .failed, .cancelled: listening = false
                default: listening = nil
                }
                guard let listening, !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: listening)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                guard !resumed else { return }
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ManagerError.launchctlFailed(
                output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300).description)
        }
    }

    private func readToken(_ file: URL) -> String? {
        (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The admin token for the managed server, for saveConnection handoff.
    func adminToken() -> String? {
        let dataDirectory = paths.installedMarker()?.marker.dataDirectoryURL ?? paths.dataDirectory
        return readToken(dataDirectory.appendingPathComponent("admin-token"))
    }

    func install() async {
        // Claim the installing state before the first await (model checks can
        // take minutes) so a second click cannot run a competing install.
        if case .installing = state { return }
        state = .installing("Checking models")
        do {
            try await performInstall()
            state = .installed
            portOccupiedByOther = false
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func performInstall() async throws {
        guard let serverDirectory = paths.bundledServerDirectory else { throw ManagerError.noBundledServer }
        let models = await ModelDownloadManager.verifiedStatus(modelsDirectory: paths.modelsDirectory)
        guard models.speech == .installed, models.text == .installed else {
            throw ManagerError.modelsMissing
        }
        if await Self.portIsListening(8391) { throw ManagerError.portInUse }
        guard let templateURL = Bundle.main.url(forResource: "dev.davis.inlay.server-agent", withExtension: "plist"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw ManagerError.noBundledServer
        }
        state = .installing("Preparing folders")
        // A reinstall keeps the existing install's data, token, and marker location.
        let existing = paths.installedMarker()
        let markerFile = existing?.file ?? paths.markerFile
        let dataDirectory = existing?.marker.dataDirectoryURL ?? paths.dataDirectory
        let tokenFile = dataDirectory.appendingPathComponent("admin-token")
        let fileManager = FileManager.default
        let createdData = !fileManager.fileExists(atPath: dataDirectory.path)
        try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
        var createdToken = false
        var bootstrapped = false
        do {
            if readToken(tokenFile) == nil {
                state = .installing("Creating server token")
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw ManagerError.launchctlFailed("Could not generate a token.")
                }
                let hex = bytes.map { String(format: "%02x", $0) }.joined()
                try hex.write(to: tokenFile, atomically: true, encoding: .utf8)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
                createdToken = true
            }
            state = .installing("Installing background service")
            // Placeholders sit in plist <string> text, so values are XML-escaped.
            func xml(_ value: String) -> String {
                value.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
            let rendered = template
                .replacingOccurrences(of: "__LABEL__", with: xml(paths.label))
                .replacingOccurrences(of: "__SERVER_DIR__", with: xml(serverDirectory.path))
                .replacingOccurrences(of: "__DATA_DIR__", with: xml(dataDirectory.path))
                .replacingOccurrences(of: "__MODELS_DIR__", with: xml(paths.modelsDirectory.path))
                .replacingOccurrences(of: "__TOKEN_FILE__", with: xml(tokenFile.path))
                .replacingOccurrences(of: "__LOG_DIR__", with: xml(paths.logsDirectory.path))
            try fileManager.createDirectory(at: paths.plistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try rendered.write(to: paths.plistURL, atomically: true, encoding: .utf8)
            try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(paths.label)"])
            try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.plistURL.path])
            bootstrapped = true
            state = .installing("Waiting for the server")
            for _ in 0..<50 {
                if await isAlive() { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard await isAlive() else { throw ManagerError.healthTimeout }
            let marker = LocalServerMarker(label: paths.label, plistPath: paths.plistURL.path,
                                           serverPath: serverDirectory.path,
                                           dataDirectory: dataDirectory.path, installedAt: Date())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(marker).write(to: markerFile, options: .atomic)
        } catch {
            if bootstrapped { try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(paths.label)"]) }
            try? fileManager.removeItem(at: paths.plistURL)
            if createdToken { try? fileManager.removeItem(at: tokenFile) }
            if createdData { try? fileManager.removeItem(at: dataDirectory) }
            throw error
        }
    }

    private func isAlive() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8391/v1/liveness"),
              let (_, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    func uninstall() {
        guard let (markerFile, marker) = paths.installedMarker() else {
            state = .failed(ManagerError.notOwned.localizedDescription)
            return
        }
        try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(marker.label)"])
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: marker.plistPath))
        // One service can leave both marker layouts behind; removing only the
        // preferred one would make the next detect() resurrect the install.
        try? FileManager.default.removeItem(at: markerFile)
        try? FileManager.default.removeItem(at: paths.legacyMarkerFile)
        try? FileManager.default.removeItem(at: paths.markerFile)
        state = .notInstalled
    }
}
