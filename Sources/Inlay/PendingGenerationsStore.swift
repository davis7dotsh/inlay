import Foundation
import InlayAPI

enum PendingDeliveryDisposition: String, Codable {
    case historyOnly, attempted
}

/// One released take whose delivery this Mac still owes the user. Frame counts
/// exist only so a finish that failed (for example a full server disk) can be
/// retried; no transcript text, token, or destination is ever stored here.
struct PendingGenerationEntry: Codable, Equatable {
    var id: UUID
    var endpoint: String
    var inferenceFrames: Int64?
    var originalFrames: Int64?
    /// Inference count to seal with if the server holds an unacknowledged chunk.
    var fallbackInferenceFrames: Int64? = nil
    var isTest: Bool
    var sealedAt: Date
    /// Nil for older copy-only recovery entries. Counts may be absent until the
    /// upload stops; a cancellation intent must never invent seal counts.
    var disposition: PendingDeliveryDisposition? = nil
    /// A conservative attempted receipt before dispatch, then the actual result.
    /// Retried verbatim until the server acknowledges its immutable receipt.
    var receipt: DeliveryReceipt? = nil
}

/// Persists pending generation IDs next to `client.json` so a result that
/// completes while the app is closed can be surfaced as ready to copy on
/// relaunch. Absent or unreadable file means no pending takes.
struct PendingGenerationsStore {
    let url: URL

    init(root: URL) {
        url = root.appendingPathComponent("pending-generations.json")
    }

    func load() -> [PendingGenerationEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PendingGenerationEntry].self, from: data)) ?? []
    }

    @discardableResult
    func save(_ entries: [PendingGenerationEntry]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
