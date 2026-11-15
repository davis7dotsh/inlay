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
        guard let installed = paths.installedMarker() else {
            state = .notInstalled
            portOccupiedByOther = await Self.portIsListening(8391)
            return
        }
        // Replacing Inlay.app leaves the saved LaunchAgent on Contents/Helpers/Server.
        // Point that agent at this bundle's Contents/Resources/Server before calling
        // the install healthy, so the server still starts after a reboot.
        if let serverDirectory = paths.bundledServerDirectory {
            if Self.launchAgentNeedsResourcesMove(installed.marker) {
                state = .installing("Updating background service")
                do {
                    try await retargetLaunchAgent(markerFile: installed.file, marker: installed.marker,
                                                  serverDirectory: serverDirectory)
                    state = .installed
                    portOccupiedByOther = false
                } catch {
                    state = .failed(error.localizedDescription)
                }
                return
            }
            // The plist already runs this bundle. Record that path on the marker.
            if LocalServerPaths.refersToLegacyBundledServer(installed.marker.serverPath),
               Self.savedAgentPlist(installed.marker, refersTo: serverDirectory) {
                try? recordServerPath(serverDirectory, markerFile: installed.file, marker: installed.marker)
            }
        }
        state = .installed
        portOccupiedByOther = false
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

    /// The on-disk LaunchAgent is what launchd will run. A marker that still names
    /// Helpers is not enough: the plist may already point at this bundle, or at a
    /// server the user installed from a checkout. A missing plist stays missing.
    /// `install-service.sh --uninstall` removes the agent and leaves the marker,
    /// so a leftover `serverPath` is not a reason to retarget or reinstall.
    private static func launchAgentNeedsResourcesMove(_ marker: LocalServerMarker) -> Bool {
        savedAgentPlist(marker, refersTo: LocalServerPaths.legacyBundledServerDirectory)
    }

    private static func savedAgentPlist(_ marker: LocalServerMarker, refersTo directory: URL) -> Bool {
        guard let plist = savedAgentPlistText(marker) else { return false }
        let paths = [directory.path, directory.standardizedFileURL.path, directory.resolvingSymlinksInPath().path]
        return paths.contains { path in
            plist.contains(path) || plist.contains(xmlEscaped(path))
        }
    }

    private static func savedAgentPlistText(_ marker: LocalServerMarker) -> String? {
        let urls = [URL(fileURLWithPath: marker.plistPath), LocalServerPaths.plistURL]
        var seen: [String] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if path.isEmpty || path == "/" || seen.contains(path) { continue }
            seen.append(path)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }
        return nil
    }

    private func recordServerPath(_ serverDirectory: URL, markerFile: URL, marker: LocalServerMarker) throws {
        var updated = marker
        updated.serverPath = serverDirectory.path
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: markerFile, options: .atomic)
    }

    private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Creates the admin token when the install does not already have one.
    /// Returns whether this call wrote the file, so a failed install can remove only that file.
    private func ensureAdminToken(at tokenFile: URL) throws -> Bool {
        if readToken(tokenFile) != nil { return false }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ManagerError.launchctlFailed("Could not generate a token.")
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try hex.write(to: tokenFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return true
    }

    private func renderedLaunchAgent(label: String, serverDirectory: URL, dataDirectory: URL,
                                     tokenFile: URL) throws -> String {
        guard let templateURL = Bundle.main.url(forResource: "dev.davis.inlay.server-agent", withExtension: "plist"),
              let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw ManagerError.noBundledServer
        }
        // Placeholders sit in plist <string> text, so values are XML-escaped.
        return template
            .replacingOccurrences(of: "__LABEL__", with: Self.xmlEscaped(label))
            .replacingOccurrences(of: "__SERVER_DIR__", with: Self.xmlEscaped(serverDirectory.path))
            .replacingOccurrences(of: "__DATA_DIR__", with: Self.xmlEscaped(dataDirectory.path))
            .replacingOccurrences(of: "__MODELS_DIR__", with: Self.xmlEscaped(paths.modelsDirectory.path))
            .replacingOccurrences(of: "__TOKEN_FILE__", with: Self.xmlEscaped(tokenFile.path))
            .replacingOccurrences(of: "__LOG_DIR__", with: Self.xmlEscaped(paths.logsDirectory.path))
    }

    private func waitForLiveness() async throws {
        for _ in 0..<50 {
            if await isAlive() { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard await isAlive() else { throw ManagerError.healthTimeout }
    }

    /// Rewrites the owned LaunchAgent onto the current bundled server and reloads it.
    /// Data, token, and marker location stay where the existing install put them.
    /// A failed reload restores the previous plist and leaves the marker unchanged.
    private func retargetLaunchAgent(markerFile: URL, marker: LocalServerMarker,
                                     serverDirectory: URL) async throws {
        let label = marker.label.isEmpty ? paths.label : marker.label
        let plistURL = marker.plistPath.isEmpty ? paths.plistURL : URL(fileURLWithPath: marker.plistPath)
        let dataDirectory = marker.dataDirectoryURL
        let tokenFile = dataDirectory.appendingPathComponent("admin-token")
        let rendered = try renderedLaunchAgent(label: label, serverDirectory: serverDirectory,
                                               dataDirectory: dataDirectory, tokenFile: tokenFile)
        let fileManager = FileManager.default
        let previousPlist = try? Data(contentsOf: plistURL)
        var createdToken = false
        var wrotePlist = false
        var bootstrapped = false
        do {
            try fileManager.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: paths.logsDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            createdToken = try ensureAdminToken(at: tokenFile)
            try rendered.write(to: plistURL, atomically: true, encoding: .utf8)
            wrotePlist = true
            try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
            try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
            bootstrapped = true
            state = .installing("Waiting for the server")
            try await waitForLiveness()
            var updated = marker
            updated.label = label
            updated.plistPath = plistURL.path
            updated.serverPath = serverDirectory.path
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(updated).write(to: markerFile, options: .atomic)
        } catch {
            if bootstrapped { try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"]) }
            if wrotePlist {
                if let previousPlist {
                    try? previousPlist.write(to: plistURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: plistURL)
                }
            }
            if createdToken { try? fileManager.removeItem(at: tokenFile) }
            throw error
        }
    }

    private func performInstall() async throws {
        guard let serverDirectory = paths.bundledServerDirectory else { throw ManagerError.noBundledServer }
        let models = await ModelDownloadManager.verifiedStatus(modelsDirectory: paths.modelsDirectory)
        guard models.speech == .installed, models.text == .installed else {
            throw ManagerError.modelsMissing
        }
        if await Self.portIsListening(8391) { throw ManagerError.portInUse }
        // A reinstall keeps the existing install's data, token, and marker location.
        let existing = paths.installedMarker()
        let markerFile = existing?.file ?? paths.markerFile
        let dataDirectory = existing?.marker.dataDirectoryURL ?? paths.dataDirectory
        let tokenFile = dataDirectory.appendingPathComponent("admin-token")
        // Read the template before creating directories so a missing template leaves the disk untouched.
        let rendered = try renderedLaunchAgent(label: paths.label, serverDirectory: serverDirectory,
                                               dataDirectory: dataDirectory, tokenFile: tokenFile)
        state = .installing("Preparing folders")
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
                createdToken = try ensureAdminToken(at: tokenFile)
            }
            state = .installing("Installing background service")
            try fileManager.createDirectory(at: paths.plistURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try rendered.write(to: paths.plistURL, atomically: true, encoding: .utf8)
            try? run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(paths.label)"])
            try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", paths.plistURL.path])
            bootstrapped = true
            state = .installing("Waiting for the server")
            try await waitForLiveness()
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
