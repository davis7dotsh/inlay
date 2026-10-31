import Foundation

/// Compares this build with the newest published GitHub release when asked.
/// Inlay never replaces itself; a newer release opens its download page.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case current
        case noRelease
        case available(version: String, page: URL)
        case failed(String)
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/davis7dotsh/inlay/releases/latest")!

    @Published private(set) var state: State = .idle
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do { state = try await latestState() }
            catch { state = .failed("Couldn’t check for updates: \(error.localizedDescription)") }
        }
    }

    private func latestState() async throws -> State {
        var request = URLRequest(url: Self.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // GitHub answers 404 until the first non-prerelease is published.
        if status == 404 { return .noRelease }
        guard status == 200 else { return .failed("GitHub didn’t answer the update check (HTTP \(status)). Try again later.") }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let latest = Self.components(release.tagName), release.htmlURL.host == "github.com" else {
            return .failed("The latest release (\(release.tagName)) has no version Inlay can compare.")
        }
        if let current = Self.components(currentVersion), !current.lexicographicallyPrecedes(latest) { return .current }
        return .available(version: latest.map(String.init).joined(separator: "."), page: release.htmlURL)
    }

    /// "v1.2.0", "client-v1.2", or "1.2.0" → [1, 2, 0], padded to three parts
    /// so 1.2 and 1.2.0 compare equal. Prerelease suffixes are ignored.
    private static func components(_ tag: String) -> [Int]? {
        var version = Substring(tag)
        if version.hasPrefix("client-") { version = version.dropFirst("client-".count) }
        if version.hasPrefix("v") { version = version.dropFirst() }
        let core = version.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
    }
}
