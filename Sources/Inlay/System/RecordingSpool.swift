import Foundation
import InlayAPI

/// Persisted next to the spool's PCM so a take survives a crash, quit, or
/// server outage. No transcript, token, or destination is ever stored here.
struct RecordingSpoolManifest: Codable, Equatable {
    var id: UUID
    var createdAt: Date
    var isTest: Bool
    /// The server this take belongs to. Recovery only uploads it there, so a
    /// take is never duplicated onto, or sent to, a different server.
    var endpoint: String?
    /// Interleaved float32 original audio, when this take archives it.
    var originalSampleRate: Int?
    var originalChannels: Int?
    /// Set on release. A spool without it was cut short by a crash or quit.
    var finished = false
    /// Stable request ID for re-uploading to a fresh generation, so a retried
    /// create replays instead of admitting a duplicate take.
    var uploadRequestID: UUID?
    /// The generation a seal was sent for, and the exact counts it used.
    var sealingGenerationID: UUID?
    var sealedInferenceFrames: Int64?
    var sealedOriginalFrames: Int64?
}

/// The durable copy of one take: headerless little-endian float32 PCM
/// (inference 16 kHz mono; original interleaved at the input format) in the
/// client data directory. Capture appends; uploads tail the same files, so a
/// stalled connection never stops the microphone. The spool is deleted only
/// once the server has sealed the take or the user discards it.
final class RecordingSpool: @unchecked Sendable {
    enum State: Sendable { case recording, finished, cancelled }

    struct Snapshot: Sendable {
        let inferenceBytes: Int64
        let originalBytes: Int64
        let originalFormat: AudioStreamFormat?
        let state: State
    }

    let id: UUID
    let directory: URL
    var inferenceURL: URL { directory.appendingPathComponent("inference.f32") }
    var originalURL: URL { directory.appendingPathComponent("original.f32") }
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private let lock = NSLock()
    private var manifestValue: RecordingSpoolManifest
    private var inferenceBytes: Int64 = 0
    private var originalBytes: Int64 = 0
    private var state: State = .recording

    private init(directory: URL, manifest: RecordingSpoolManifest) {
        id = manifest.id
        self.directory = directory
        manifestValue = manifest
    }

    static func root(in clientRoot: URL) -> URL {
        clientRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    static func create(in clientRoot: URL, id: UUID, endpoint: String, isTest: Bool) throws -> RecordingSpool {
        let files = FileManager.default
        let root = root(in: clientRoot)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let spool = RecordingSpool(directory: directory, manifest: .init(id: id, createdAt: Date(), isTest: isTest, endpoint: endpoint))
        do { try spool.write(spool.manifestValue) } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        return spool
    }

    /// Spools left behind by earlier sessions. Their capture is over, so the
    /// byte counts come from the files, trimmed to whole frames and to the
    /// interval both streams cover.
    static func saved(in clientRoot: URL) -> [RecordingSpool] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: root(in: clientRoot), includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? InlayAPI.decoder().decode(RecordingSpoolManifest.self, from: data),
                  manifest.id == id else { return nil }
            let spool = RecordingSpool(directory: directory, manifest: manifest)
            func size(_ url: URL) -> Int64 {
                ((try? files.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            }
            var inference = size(spool.inferenceURL) / 4 * 4
            var original: Int64 = 0
            if let rate = manifest.originalSampleRate, let channels = manifest.originalChannels, rate > 0, channels > 0 {
                let frameBytes = Int64(channels * 4)
                original = size(spool.originalURL) / frameBytes * frameBytes
                // Capture writes the original before its converted copy, so an
                // interrupted take can hold slightly more of one stream.
                let inferenceSeconds = Double(inference / 4) / 16_000
                let originalSeconds = Double(original / frameBytes) / Double(rate)
                if originalSeconds > inferenceSeconds {
                    original = Int64(inferenceSeconds * Double(rate)) * frameBytes
                } else {
                    inference = Int64(originalSeconds * 16_000) * 4
                }
            }
            spool.lock.withLock {
                spool.inferenceBytes = inference
                spool.originalBytes = original
                spool.state = .finished
            }
            return spool
        }
    }

    var manifest: RecordingSpoolManifest { lock.withLock { manifestValue } }

    func snapshot() -> Snapshot {
        lock.withLock {
            let format = manifestValue.originalSampleRate.flatMap { rate in
                manifestValue.originalChannels.map { AudioStreamFormat(sampleRate: rate, channels: $0) }
            }
            return Snapshot(inferenceBytes: inferenceBytes, originalBytes: originalBytes,
                            originalFormat: format, state: state)
        }
    }

    /// Writer queue only: counts bytes already written to the spool files.
    func appended(inference: Int = 0, original: Int = 0) {
        lock.withLock {
            inferenceBytes += Int64(inference)
            originalBytes += Int64(original)
        }
    }

    /// Persists before returning. Callers must not contact the server on a
    /// failure: the manifest is what prevents duplicate creates and seals.
    func update(_ change: (inout RecordingSpoolManifest) -> Void) throws {
        try lock.withLock {
            var next = manifestValue
            change(&next)
            try write(next)
            manifestValue = next
        }
    }

    /// Capture ended; uploads drain what was written. Idempotent.
    func finish() {
        lock.withLock {
            guard state == .recording else { return }
            state = .finished
            manifestValue.finished = true
            try? write(manifestValue)
        }
    }

    /// The user discarded the take: stop uploads and delete the audio.
    func discard() {
        lock.withLock { state = .cancelled }
        delete()
    }

    func delete() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Callers hold the lock (or own the spool exclusively), so saves never
    /// reorder. The replacement reaches stable storage, rename included,
    /// before this returns: a seal marker must survive power loss.
    private func write(_ manifest: RecordingSpoolManifest) throws {
        let data = try InlayAPI.encoder().encode(manifest)
        let temporary = directory.appendingPathComponent(".manifest-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let file = try FileHandle(forWritingTo: temporary)
            defer { try? file.close() }
            try file.write(contentsOf: data)
            try Self.fullSync(file.fileDescriptor)
            guard rename(temporary.path, manifestURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let folder = open(directory.path, O_RDONLY)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        try Self.fullSync(folder)
    }

    /// fsync alone leaves data in the drive's cache on macOS.
    private static func fullSync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
