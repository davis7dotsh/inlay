import Darwin
import Foundation
import InlayAPI

/// Persisted next to the spool's PCM so a take survives a crash, quit, or
/// server outage. No transcript, token, or insertion target is stored here.
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
    // Older clients require this field; recovery itself uses on-disk lengths.
    var finished = false
    /// Stable request ID for re-uploading to a fresh generation, so a retried
    /// create replays instead of admitting a duplicate take.
    var uploadRequestID: UUID?
    /// The generation a seal was sent for, and the exact counts it used.
    var sealingGenerationID: UUID?
    var sealedInferenceFrames: Int64?
    var sealedOriginalFrames: Int64?
    var continuationID: UUID?
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
    let maximumSeconds: Int
    let directory: URL
    var inferenceURL: URL { directory.appendingPathComponent("inference.f32") }
    var originalURL: URL { directory.appendingPathComponent("original.f32") }
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private let lock = NSLock()
    private var manifestValue: RecordingSpoolManifest
    private var inferenceBytes: Int64 = 0
    private var originalBytes: Int64 = 0
    private var state: State = .recording
    private var originalOmitted = false
    private static let discardPrefix = ".discarded-"

    private init(directory: URL, manifest: RecordingSpoolManifest, maximumSeconds: Int = InlayAPI.maximumRecordingSeconds) {
        id = manifest.id
        self.maximumSeconds = min(InlayAPI.maximumRecordingSeconds, max(1, maximumSeconds))
        self.directory = directory
        manifestValue = manifest
    }

    static func root(in clientRoot: URL) -> URL {
        clientRoot.appendingPathComponent("recordings", isDirectory: true)
    }

    static func create(in clientRoot: URL, id: UUID, endpoint: String, isTest: Bool,
                       maximumSeconds: Int = InlayAPI.maximumRecordingSeconds) throws -> RecordingSpool {
        let files = FileManager.default
        let root = root(in: clientRoot)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let spool = RecordingSpool(directory: directory, manifest: .init(id: id, createdAt: Date(), isTest: isTest, endpoint: endpoint),
                                   maximumSeconds: maximumSeconds)
        do {
            try spool.write(spool.manifestValue)
            // Sync the new take's entry in recordings/, and recordings/ itself
            // on first use. Syncing the manifest alone cannot persist either.
            try syncDirectory(root)
            try syncDirectory(clientRoot)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        return spool
    }

    /// Spools left behind by earlier sessions. Their capture is over, so the
    /// byte counts come from the files. Never shorten speech to match a
    /// missing or damaged optional archival copy.
    static func saved(in clientRoot: URL) -> [RecordingSpool] {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: root(in: clientRoot), includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap { directory in
            let name = directory.lastPathComponent
            if name.hasPrefix(discardPrefix), UUID(uuidString: String(name.dropFirst(discardPrefix.count))) != nil {
                // A previous discard committed its rename but not its cleanup.
                // This is never a candidate for upload, even if removal fails.
                try? files.removeItem(at: directory)
                return nil
            }
            guard let id = UUID(uuidString: name) else { return nil }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? InlayAPI.decoder().decode(RecordingSpoolManifest.self, from: data),
                  manifest.id == id else { return nil }
            let spool = RecordingSpool(directory: directory, manifest: manifest)
            // A missing file can be the result of a crash during startup. An
            // unreadable file is different: skip this take rather than treat
            // it as empty and let recovery delete it.
            func size(_ url: URL) -> Int64? {
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else { return errno == ENOENT ? 0 : nil }
                guard metadata.st_mode & S_IFMT == S_IFREG else { return nil }
                return metadata.st_size
            }
            guard let speechSize = size(spool.inferenceURL), let originalSize = size(spool.originalURL) else { return nil }
            let inference = speechSize / 4 * 4
            // Bounds frame arithmetic as well as uploads of malformed files.
            guard inference / 4 <= Int64(InlayAPI.maximumRecordingSeconds * 16_000) else { return nil }
            // Do not discard the only surviving recording if the inference
            // file was lost but the original is still on disk.
            let rate = manifest.originalSampleRate ?? 0, channels = manifest.originalChannels ?? 0
            let validFormat = OriginalAudioPolicy.isArchivable(sampleRate: Double(rate), channels: channels)
            if inference < 4_000 * 4 && originalSize > 0 && (!validFormat || originalSize >= Int64(rate * channels)) { return nil }
            var original: Int64 = 0
            if validFormat && originalSize <= OriginalAudioPolicy.maximumBytes {
                let frameBytes = Int64(channels * 4)
                let availableFrames = originalSize / frameBytes
                let desiredFrames = inference / 4 * Int64(rate) / 16_000
                // Converter priming can leave a few missing original frames;
                // the server accepts intervals differing by at most 75 ms.
                if inference / 4 * Int64(rate) - availableFrames * 16_000 <= Int64(rate) * 1_200 {
                    original = min(availableFrames, desiredFrames) * frameBytes
                }
            }
            spool.lock.withLock {
                spool.inferenceBytes = inference
                spool.originalBytes = original
                spool.originalOmitted = original == 0
                spool.state = .finished
            }
            return spool
        }
    }

    var manifest: RecordingSpoolManifest { lock.withLock { manifestValue } }

    func snapshot() -> Snapshot {
        lock.withLock {
            let format = originalOmitted ? nil : manifestValue.originalSampleRate.flatMap { rate in
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

    /// Even if part of the original was already uploaded, finish must omit
    /// it. The server can still seal the complete inference stream by itself.
    func omitOriginal() {
        lock.withLock { originalOmitted = true }
    }

    /// Persists before returning. Callers must not contact the server on a
    /// failure: the manifest is what prevents duplicate creates and seals.
    func update(_ change: (inout RecordingSpoolManifest) -> Void) throws {
        try lock.withLock {
            guard state != .cancelled else { throw CancellationError() }
            var next = manifestValue
            change(&next)
            try write(next)
            manifestValue = next
        }
    }

    func recordSeal(id: UUID, finish: FinishGenerationRequest) throws {
        try update {
            $0.sealingGenerationID = id
            $0.sealedInferenceFrames = finish.inferenceFrames
            $0.sealedOriginalFrames = finish.originalFrames
            $0.continuationID = finish.continuationID
        }
    }

    /// Capture ended; uploads drain what was written. Idempotent.
    func finish() {
        lock.withLock {
            guard state == .recording else { return }
            state = .finished
            manifestValue.finished = true
        }
    }

    /// Commit the user's decision before recursively deleting any audio. Even
    /// older clients only recover UUID directories, never the quarantined name.
    func discard() throws {
        let parent = directory.deletingLastPathComponent()
        let discarded = parent.appendingPathComponent(Self.discardPrefix + id.uuidString, isDirectory: true)
        try lock.withLock {
            state = .cancelled
            if rename(directory.path, discarded.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // If the take was already removed after sealing, make that unlink
            // durable too. A successful discard cannot reappear on relaunch.
            try Self.syncDirectory(parent)
        }
        if (try? FileManager.default.removeItem(at: discarded)) != nil { try? Self.syncDirectory(parent) }
    }

    func delete() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Callers hold the lock (or own the spool exclusively), so saves never
    /// reorder. The replacement reaches stable storage, rename included,
    /// before this returns: a seal marker must survive power loss.
    private func write(_ manifest: RecordingSpoolManifest) throws {
        try Self.replacePrivateFile(at: manifestURL, with: InlayAPI.encoder().encode(manifest))
    }

    /// The caller owns the directory. Both the content and its replacement
    /// directory entry must reach storage before a subsequent network action.
    static func replacePrivateFile(at url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try fullSync(descriptor)
            try file.close()
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? file.close()
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try Self.syncDirectory(directory)
    }

    static func syncDirectory(_ directory: URL) throws {
        let folder = open(directory.path, O_RDONLY)
        guard folder >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(folder) }
        try Self.fullSync(folder)
    }

    /// On filesystems that support it, flush the drive cache too. Fall back
    /// only when the operation itself is unsupported, never on an I/O error.
    static func fullSync(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        if [EINVAL, ENOTSUP, ENOTTY, ENOSYS].contains(errno), fsync(descriptor) == 0 { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
