import Foundation
import InlayAPI

/// The audio writer publishes a synced checkpoint about every quarter second.
/// The uploader reads immutable chunks from disk, so a stalled network never
/// grows a PCM queue in memory. Recovery replays byte-identical upload batches.
final class AudioChunkPipe: @unchecked Sendable, Identifiable {
    private struct Manifest: Codable {
        var version = 2
        // Version 1 embedded this immutable snapshot in every checkpoint.
        // Version 2 keeps it once in record.json, outside the audio writer's hot path.
        var record: GenerationRecord?
        let endpoint: URL
        let deviceID: String
        var chunks = 0
        var inferenceFrames: Int64 = 0
        var originalFrames: Int64 = 0
        var sealed = false
    }
    private struct Chunk: Codable {
        let original: Bool
        let data: Data
        let sampleRate: Double
        let channels: Int
    }
    let directory: URL
    private let lock = NSRecursiveLock()
    private let generation: GenerationRecord
    private var manifest: Manifest
    private var pending: [Chunk] = []
    private var pendingBytes = 0
    private var pendingFrames = 0
    private var cancelled = false
    private var failure: Error?
    private let onFailure: (@Sendable (Error) -> Void)?

    var id: UUID { generation.id }
    var record: GenerationRecord { generation }
    var endpoint: URL { lock.withLock { manifest.endpoint } }
    var deviceID: String { lock.withLock { manifest.deviceID } }
    var isSealed: Bool { lock.withLock { manifest.sealed } }
    var seconds: Double { lock.withLock { Double(manifest.inferenceFrames) / 16_000 } }

    init(root: URL, record: GenerationRecord, endpoint: URL, deviceID: String,
         onFailure: (@Sendable (Error) -> Void)? = nil) throws {
        directory = root.appendingPathComponent(record.id.uuidString, isDirectory: true)
        generation = record
        manifest = Manifest(record: nil, endpoint: endpoint, deviceID: deviceID)
        self.onFailure = onFailure
        guard !FileManager.default.fileExists(atPath: directory.path), endpoint.user == nil,
              endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil else {
            throw ServerClientError.invalidEndpoint
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try durableWrite(InlayAPI.encoder().encode(record), to: directory.appendingPathComponent("record.json"))
        try save()
        try syncDirectory(root)
        try syncDirectory(root.deletingLastPathComponent())
    }

    private init(recovering directory: URL) throws {
        self.directory = directory
        onFailure = nil
        manifest = try InlayAPI.decoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        if manifest.version == 1, let record = manifest.record { generation = record }
        else {
            generation = try InlayAPI.decoder().decode(GenerationRecord.self, from: Data(contentsOf: directory.appendingPathComponent("record.json")))
        }
        guard [1, 2].contains(manifest.version), manifest.chunks >= 0, manifest.chunks <= 10_000_000,
              manifest.inferenceFrames >= 0, manifest.originalFrames >= 0,
              generation.id.uuidString == directory.lastPathComponent else { throw ServerClientError.invalidResponse }
        if manifest.version == 1 {
            // Commit the immutable record before removing it from the manifest;
            // either checkpoint remains readable if migration is interrupted.
            try durableWrite(InlayAPI.encoder().encode(generation), to: directory.appendingPathComponent("record.json"))
            manifest.version = 2
            manifest.record = nil
            try save()
        }
        // An uncommitted suffix was never made available to the uploader.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if file.pathExtension == "chunk", let index = Int(file.deletingPathExtension().lastPathComponent), index >= manifest.chunks {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    static func recover(in root: URL, excluding live: Set<UUID> = []) -> [AudioChunkPipe] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        // Unreadable captures remain on disk. Never delete them as orphans.
        return entries.compactMap {
            guard let id = UUID(uuidString: $0.lastPathComponent), !live.contains(id),
                  let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return try? AudioChunkPipe(recovering: $0)
        }
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory(url.deletingLastPathComponent())
    }
    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private func save() throws {
        try durableWrite(InlayAPI.encoder().encode(manifest), to: directory.appendingPathComponent("manifest.json"))
    }

    func append(_ chunk: CapturedAudioChunk) {
        do {
            try lock.withLock {
                guard !cancelled, !manifest.sealed, failure == nil else { return }
                guard chunk.channels > 0, chunk.data.count % (chunk.channels * 4) == 0,
                      pendingBytes + chunk.data.count <= 8 * 1_048_576 else { throw ServerClientError.uploadBacklog }
                pending.append(Chunk(original: chunk.kind == .original, data: chunk.data, sampleRate: chunk.sampleRate, channels: chunk.channels))
                pendingBytes += chunk.data.count
                if chunk.kind == .normalized { pendingFrames += chunk.data.count / 4 }
                if pendingFrames >= 4_000 { try flush() }
            }
        } catch {
            lock.withLock { failure = error }
            onFailure?(error)
        }
    }

    private func flush() throws {
        guard !pending.isEmpty else { return }
        if let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber,
           free.int64Value < Int64(100 * 1_048_576 + pendingBytes * 2) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        var next = manifest
        // One durable batch per checkpoint, rather than one file and fsync per
        // microphone callback. Its internal chunk boundaries stay immutable.
        try durableWrite(InlayAPI.encoder().encode(pending), to: directory.appendingPathComponent("\(next.chunks).chunk"))
        next.chunks += 1
        for chunk in pending {
            if chunk.original { next.originalFrames += Int64(chunk.data.count / (chunk.channels * 4)) }
            else { next.inferenceFrames += Int64(chunk.data.count / 4) }
        }
        try durableWrite(InlayAPI.encoder().encode(next), to: directory.appendingPathComponent("manifest.json"))
        manifest = next
        pending.removeAll(keepingCapacity: true); pendingBytes = 0; pendingFrames = 0
    }

    var stream: AsyncThrowingStream<CapturedAudioChunk, Error> {
        var index = 0
        var batch: [Chunk] = []
        var cursor = 0
        return AsyncThrowingStream(unfolding: { [self] in
            while true {
                try Task.checkCancellation()
                let state = lock.withLock { (manifest.chunks, manifest.sealed, cancelled, failure) }
                if state.2 { throw CancellationError() }
                if cursor < batch.count {
                    let chunk = batch[cursor]; cursor += 1
                    return CapturedAudioChunk(kind: chunk.original ? .original : .normalized, data: chunk.data,
                                              sampleRate: chunk.sampleRate, channels: chunk.channels)
                }
                if index < state.0 {
                    let url = directory.appendingPathComponent("\(index).chunk")
                    batch = try InlayAPI.decoder().decode([Chunk].self, from: Data(contentsOf: url))
                    cursor = 0; index += 1
                    continue
                }
                if let error = state.3 { throw error }
                if state.1 { return nil }
                try await Task.sleep(for: .milliseconds(100))
            }
        })
    }

    func finish() throws {
        try lock.withLock {
            try flush()
            var next = manifest
            next.sealed = true
            try durableWrite(InlayAPI.encoder().encode(next), to: directory.appendingPathComponent("manifest.json"))
            manifest = next
            failure = nil
        }
    }
    func cancel() { lock.withLock { cancelled = true } }
    func resume() { lock.withLock { cancelled = false; failure = nil } }
    func discard() throws {
        cancel()
        try FileManager.default.removeItem(at: directory)
        try syncDirectory(directory.deletingLastPathComponent())
    }
}
