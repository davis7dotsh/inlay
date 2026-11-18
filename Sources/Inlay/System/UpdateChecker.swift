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
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }
    }

    // Server releases (server-v*) share this repository, so pick the newest
    // app release from the list instead of trusting releases/latest.
    private static let releases = URL(string: "https://api.github.com/repos/davis7dotsh/inlay/releases?per_page=100")!

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
        var request = URLRequest(url: Self.releases)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failed("GitHub didn’t answer the update check (HTTP \(status)). Try again later.") }
        let appReleases = try JSONDecoder().decode([Release].self, from: data).compactMap { release in
            !release.draft && !release.prerelease && release.htmlURL.host == "github.com"
                ? Self.components(release.tagName).map { (version: $0, page: release.htmlURL) } : nil
        }
        guard let latest = appReleases.max(by: { $0.version.lexicographicallyPrecedes($1.version) }) else { return .noRelease }
        guard let current = Self.components(currentVersion) else {
            return .failed("This build has no version Inlay can compare.")
        }
        if !current.lexicographicallyPrecedes(latest.version) { return .current }
        return .available(version: latest.version.map(String.init).joined(separator: "."), page: latest.page)
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
