import Foundation

/// Bundle metadata is the single source of truth for app and storage identity.
public enum InlayBuild: Equatable, Sendable {
    case release, development

    // Unbundled Swift runs stay isolated from the installed app's preferences.
    public static let current: Self = Bundle.main.object(forInfoDictionaryKey: "InlayDevelopmentBuild") as? Bool == false
        ? .release : .development

    public var displayName: String { self == .development ? "Inlay Dev" : "Inlay" }
    public var isDevelopment: Bool { self == .development }
    public var bundleIdentifier: String {
        self == .development ? "dev.davis.inlay.dev" : "dev.davis.inlay"
    }
    public var credentialService: String { bundleIdentifier + ".server" }
    public var windowAutosaveName: String { self == .development ? "InlayDevMainWindow" : "InlayMainWindow" }
    public var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(displayName, isDirectory: true)
    }
}
