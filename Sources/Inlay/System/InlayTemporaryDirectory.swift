import Foundation
import InlayCore

enum InlayTemporaryDirectory {
    static let url: URL = {
        guard InlayBuild.current.isDevelopment,
              let root = ProcessInfo.processInfo.environment["INLAY_CLIENT_DATA_DIR"], !root.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return directory
    }()
}
