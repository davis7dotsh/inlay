import Foundation
import Crypto
import InlayAPI
import InlayDomain

public struct ServiceError: LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
}

/// The sole owner of durable product state. Actor isolation serializes admission,
/// chunk commits and preference revisions; native inference never blocks this actor.
public actor GenerationService {
    private static let maximumMetadataBytes = 1_048_576
    private static let maximumPreferencesBytes = 262_144
    private static let maximumDictionaryOutputBytes = 24 * 1_024
    private struct Chunk {
        var offset: UInt64
        var count: Int
    }
    private struct Upload {
        var format: AudioStreamFormat
        var chunks: [Chunk] = []
        var bytes: Int64 = 0
        var frameCount: Int64 { bytes / Int64(format.channels * 4) }
    }
    private struct ImportStage {
        var request: WisprFlowImportRequest
        var directory: URL
        var uploaded: Set<WisprFlowArtifactName> = []
        var touchedAt = Date()
    }
    private let configuration: ServerConfiguration
    private let inference: NativeInference
    private var preferences: PreferencesSnapshot
    private var records: [UUID: GenerationRecord] = [:]
    private var wisprFlowIndex: [UUID: UUID] = [:]
    private var importStages: [UUID: ImportStage] = [:]
    private var uploads: [UUID: [AudioKind: Upload]] = [:]
    private struct QueuedGeneration {
        let id: UUID
        let previous: DictationContinuation?
    }
    private var queue: [QueuedGeneration] = []
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var speechLoadFailed = false
    private var warming = false
    private var stopping = false
    private var subscribers: [UUID: [UUID: AsyncStream<GenerationRecord>.Continuation]] = [:]

    public init(configuration: ServerConfiguration, inference: NativeInference? = nil) throws {
        self.configuration = configuration
        self.inference = inference ?? NativeInference(configuration: configuration.inference)
        let files = FileManager.default
        try files.createDirectory(at: configuration.dataDirectory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let directory = configuration.dataDirectory.appendingPathComponent("generations", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ServiceError(500, "invalid_storage", "The generations directory must not be a symbolic link.")
        }
        let importRoots = ["imports", "imports/wispr-flow", "imports/wispr-flow/staging"]
            .map { configuration.dataDirectory.appendingPathComponent($0, isDirectory: true) }
        for root in importRoots {
            if !files.fileExists(atPath: root.path) {
                try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceError(500, "invalid_storage", "Import storage directories must not be symbolic links.")
            }
        }
        let imports = importRoots[2]
        // Incomplete imports are never published. A new run starts from its source
        // manifest, so stale staging files can be discarded after a server restart.
        for child in try files.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil) {
            if UUID(uuidString: child.lastPathComponent) != nil { try files.removeItem(at: child) }
        }
        let preferencesURL = configuration.dataDirectory.appendingPathComponent("preferences.json")
        if files.fileExists(atPath: preferencesURL.path) {
            let attributes = try files.attributesOfItem(atPath: preferencesURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumPreferencesBytes else {
                throw ServiceError(500, "invalid_preferences", "Server preferences must be a regular JSON file of at most 256 KiB.")
            }
            preferences = try InlayAPI.decoder().decode(PreferencesSnapshot.self, from: Data(contentsOf: preferencesURL))
            if let error = preferences.preferences.validationError { throw ServiceError(500, "invalid_preferences", error) }
        } else {
            preferences = PreferencesSnapshot()
            try InlayAPI.encoder().encode(preferences).write(to: preferencesURL, options: .atomic)
        }
        for child in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            guard try files.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ServiceError(500, "invalid_archive", "Generation directories must not be symbolic links.")
            }
            let metadata = child.appendingPathComponent("metadata.json")
            guard files.fileExists(atPath: metadata.path) else { continue }
            let metadataAttributes = try files.attributesOfItem(atPath: metadata.path)
            guard metadataAttributes[.type] as? FileAttributeType == .typeRegular,
                  let metadataSize = metadataAttributes[.size] as? NSNumber, metadataSize.intValue <= Self.maximumMetadataBytes else {
                throw ServiceError(500, "invalid_archive", "Generation metadata must be a regular JSON file of at most 1 MiB.")
            }
            var record = try InlayAPI.decoder().decode(GenerationRecord.self, from: Data(contentsOf: metadata))
            guard record.id == id, record.schemaVersion == 1 else { throw ServiceError(500, "invalid_archive", "A generation has invalid metadata.") }
            if !record.status.isTerminal {
                record.status = .failed
                record.error = "Server restarted before this generation completed."
                record.updatedAt = Date()
                record.progress = nil
                for name in ["inference.raw", "original.raw", "inference.wav.partial", "original.wav.partial"] {
                    try? files.removeItem(at: child.appendingPathComponent(name))
                }
                let recovered = try InlayAPI.encoder().encode(record)
                // Recovery adds an error message. If a nearly full record has
                // no room for it, leave its readable on-disk snapshot intact.
                if recovered.count <= Self.maximumMetadataBytes { try recovered.write(to: metadata, options: .atomic) }
            }
            records[id] = record
            if let source = record.importedSource, source.provider == "wispr-flow" {
                guard wisprFlowIndex[source.sourceID] == nil else {
                    throw ServiceError(500, "duplicate_import", "The archive contains duplicate Wispr Flow source IDs.")
                }
                wisprFlowIndex[source.sourceID] = id
            }
        }
    }

    public func start() {
        guard !stopping else { return }
        beginWarmup()
        guard expiryTask == nil else { return }
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await self?.heartbeat()
                await self?.expireUploads()
                await self?.expireImportStages()
            }
        }
    }

    public func shutdown() async {
        stopping = true
        expiryTask?.cancel(); expiryTask = nil
        warmTask?.cancel(); warmTask = nil
        for id in records.values.filter({ !$0.status.isTerminal }).map(\.id) {
            _ = try? await cancel(id)
        }
        queue.removeAll()
        await inference.shutdown()
        for group in subscribers.values { for continuation in group.values { continuation.finish() } }
        subscribers.removeAll()
    }

    public func health() async -> ServerHealth {
        let state = await inference.readiness(proofreadingEnabled: false)
        let writable = FileManager.default.isWritableFile(atPath: configuration.dataDirectory.path) && (try? requireDiskSpace()) != nil
        // Queue recordings through a reload, but not behind a helper that failed to start.
        let unloadable = speechLoadFailed && !state.speechLoaded
        let ready = !stopping && state.available && writable && !unloadable
        let message = stopping ? "The server is shutting down." : (!writable ? "Server storage is unavailable or full." :
            (ready ? (state.speechLoaded ? "Server ready." : "Loading server models; recordings will queue.") :
                (unloadable ? "Speech model failed to load." :
                    (warming ? "Loading server models…" : "Server models are unavailable."))))
        if !state.speechLoaded, !warming, activeID == nil { beginWarmup() }
        return ServerHealth(isDev: configuration.development, ready: ready,
            speech: ModelRuntimeInfo(modelID: "whisper-large-v3-turbo", backend: Self.speechBackend, ready: state.speechLoaded),
            proofreading: ModelRuntimeInfo(modelID: "Qwen3-4B-Instruct-2507", backend: Self.proofBackend,
                                           ready: state.proofLoaded, message: preferences.preferences.textCorrectionEnabled ?
                                               (state.proofLoaded ? nil : "Unavailable; deterministic text is preserved.") : "Disabled"),
            message: message)
    }

    public func getPreferences() -> PreferencesSnapshot { preferences }

    public func updatePreferences(_ update: PreferencesSnapshot) throws -> PreferencesSnapshot {
        guard update.revision == preferences.revision else { throw ServiceError(409, "stale_preferences", "Preferences changed on another device. Reload and try again.") }
        if let error = update.preferences.validationError { throw ServiceError(400, "invalid_preferences", error) }
        let next = PreferencesSnapshot(revision: preferences.revision + 1, preferences: update.preferences)
        let data = try InlayAPI.encoder().encode(next)
        guard data.count <= Self.maximumPreferencesBytes else {
            throw ServiceError(413, "preferences_too_large", "Server preferences exceeded the 256 KiB storage limit.")
        }
        try data.write(to: configuration.dataDirectory.appendingPathComponent("preferences.json"), options: .atomic)
        preferences = next
        if activeID == nil { beginWarmup() }
        return next
    }

    public func create(_ request: CreateGenerationRequest) async throws -> GenerationRecord {
        guard !stopping else { throw ServiceError(503, "server_stopping", "The server is shutting down.") }
        guard validLabel(request.device.id, limit: 128), validLabel(request.device.name, limit: 128) else {
            throw ServiceError(400, "invalid_device", "Device ID and name must be nonempty single-line text of at most 128 characters.")
        }
        if let existing = records.values.first(where: { $0.requestID == request.requestID && $0.device.id == request.device.id }) { return existing }
        let state = await inference.readiness(proofreadingEnabled: false)
        guard state.available else { beginWarmup(); throw ServiceError(503, "server_unavailable", state.message) }
        guard !speechLoadFailed || state.speechLoaded else {
            beginWarmup(); throw ServiceError(503, "server_unavailable", "Speech model failed to load.")
        }
        if !state.speechLoaded { beginWarmup() }
        // Readiness suspends the actor; recheck shutdown and duplicate requests.
        guard !stopping else { throw ServiceError(503, "server_stopping", "The server is shutting down.") }
        if let existing = records.values.first(where: { $0.requestID == request.requestID && $0.device.id == request.device.id }) { return existing }
        try requireDiskSpace()
        let record = GenerationRecord(requestID: request.requestID, device: request.device, mode: request.mode, settings: preferences)
        try FileManager.default.createDirectory(at: directory(record.id), withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try save(record)
        uploads[record.id] = [:]
        return record
    }

    public func appendAudio(_ id: UUID, kind: AudioKind, sequence: Int, format: AudioStreamFormat, data: Data) throws -> AudioChunkReceipt {
        var record = try get(id)
        guard record.status == .receiving else { throw ServiceError(409, "upload_closed", "This recording is no longer accepting audio.") }
        guard kind != .original || record.settings.preferences.keepOriginalAudio else { throw ServiceError(400, "original_disabled", "Original audio retention was disabled for this recording.") }
        guard sequence >= 0, sequence < 4096 else { throw ServiceError(413, "chunk_limit", "This recording exceeded its audio chunk limit.") }
        guard (8_000...192_000).contains(format.sampleRate), (1...8).contains(format.channels),
              kind != .inference || format == AudioStreamFormat(sampleRate: 16_000, channels: 1) else {
            throw ServiceError(400, "invalid_format", "Inference audio must be mono 16 kHz. Original audio must have 1–8 channels at 8–192 kHz.")
        }
        guard !data.isEmpty, data.count <= InlayAPI.maximumChunkBytes, data.count % (format.channels * 4) == 0 else {
            throw ServiceError(data.count > InlayAPI.maximumChunkBytes ? 413 : 400, "invalid_chunk", "Audio chunks must contain complete float32 frames and fit within 1 MiB.")
        }
        guard Self.finiteSamples(data) else { throw ServiceError(400, "invalid_samples", "Audio must contain finite float32 samples.") }
        var upload = uploads[id]?[kind] ?? Upload(format: format)
        guard upload.format == format else { throw ServiceError(409, "format_changed", "An audio stream cannot change format during recording.") }
        let raw = directory(id).appendingPathComponent("\(kind.rawValue).raw")
        if sequence < upload.chunks.count {
            let chunk = upload.chunks[sequence]
            let handle = try FileHandle(forReadingFrom: raw)
            defer { try? handle.close() }
            try handle.seek(toOffset: chunk.offset)
            guard chunk.count == data.count, try handle.read(upToCount: chunk.count) == data else {
                throw ServiceError(409, "conflicting_chunk", "A repeated audio chunk did not match the original.")
            }
            return AudioChunkReceipt(nextSequence: upload.chunks.count, frameCount: upload.frameCount)
        }
        guard sequence == upload.chunks.count else { throw ServiceError(409, "missing_chunk", "Audio chunks must arrive in sequence.") }
        let nextBytes = upload.bytes + Int64(data.count)
        let duration = Double(nextBytes) / Double(format.sampleRate * format.channels * 4)
        guard duration <= Double(InlayAPI.maximumRecordingSeconds) + 0.1, nextBytes <= 268_435_456 else {
            throw ServiceError(413, "recording_limit", "Recordings are limited to 180 seconds and 256 MiB per audio stream.")
        }
        try requireDiskSpace()
        if upload.bytes == 0 { try Data().write(to: raw, options: .atomic) }
        let handle = try FileHandle(forWritingTo: raw)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(upload.bytes))
        try handle.write(contentsOf: data)
        upload.chunks.append(Chunk(offset: UInt64(upload.bytes), count: data.count))
        upload.bytes = nextBytes
        uploads[id, default: [:]][kind] = upload
        record.updatedAt = Date()
        records[id] = record
        return AudioChunkReceipt(nextSequence: upload.chunks.count, frameCount: upload.frameCount)
    }

    public func finish(_ id: UUID, request: FinishGenerationRequest) throws -> GenerationRecord {
        var record = try get(id)
        if record.status != .receiving {
            guard record.inferenceAudio?.frameCount == request.inferenceFrames,
                  record.originalAudio?.frameCount == request.originalFrames else {
                throw ServiceError(409, "conflicting_finish", "The recording was already sealed with different audio counts.")
            }
            return record
        }
        guard let streams = uploads[id], let speech = streams[.inference], speech.frameCount == request.inferenceFrames else {
            throw ServiceError(409, "incomplete_audio", "Inference audio has not been completely uploaded.")
        }
        let duration = Double(speech.frameCount) / 16_000
        guard duration >= 0.25, duration <= 180 else { throw ServiceError(400, "invalid_duration", "Recordings must be between 0.25 and 180 seconds.") }
        let original = streams[.original]
        if record.settings.preferences.keepOriginalAudio {
            guard let original, original.frameCount == request.originalFrames else { throw ServiceError(409, "incomplete_original", "Original audio has not been completely uploaded.") }
            let originalDuration = Double(original.frameCount) / Double(original.format.sampleRate)
            guard abs(originalDuration - duration) <= 0.075 else { throw ServiceError(400, "audio_mismatch", "Original and inference audio must cover the same recording interval.") }
        } else if request.originalFrames != nil || original != nil {
            throw ServiceError(400, "unexpected_original", "This recording does not retain original audio.")
        }
        let previous = continuation(request.continuationID, for: record)
        do {
            record.inferenceAudio = try seal(speech, kind: .inference, id: id)
            if let original { record.originalAudio = try seal(original, kind: .original, id: id) }
            record.status = .queued
            record.updatedAt = Date()
            record.progress = 0
            try save(record)
        } catch {
            record.status = .failed
            record.error = "The server could not preserve the complete recording."
            record.updatedAt = Date()
            do { try save(record) } catch { publish(record) }
            cleanPartial(id)
            throw ServiceError(500, "audio_storage_failed", "The server could not preserve the complete recording.")
        }
        uploads[id] = nil
        queue.append(QueuedGeneration(id: id, previous: previous))
        processNext()
        return record
    }

    public func get(_ id: UUID) throws -> GenerationRecord {
        guard let record = records[id] else { throw ServiceError(404, "not_found", "Recording not found.") }
        return record
    }

    public func history(limit: Int, before: String?, source: String? = nil) throws -> GenerationPage {
        guard (1...100).contains(limit) else { throw ServiceError(400, "invalid_limit", "History page size must be between 1 and 100.") }
        guard source == nil || source == "wispr-flow" || source == "inlay" else {
            throw ServiceError(400, "invalid_source", "Choose Wispr Flow or Inlay history.")
        }
        let selected = records.values.filter { record in
            switch source {
            case "wispr-flow": return record.importedSource?.provider == "wispr-flow"
            case "inlay": return record.importedSource == nil
            default: return true
            }
        }
        let sorted = selected.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString > $1.id.uuidString : $0.createdAt > $1.createdAt }
        let start: Int
        if let before {
            guard let id = UUID(uuidString: before), let index = sorted.firstIndex(where: { $0.id == id }) else {
                throw ServiceError(400, "invalid_cursor", "The history cursor is no longer valid. Reload history.")
            }
            start = index + 1
        } else { start = 0 }
        let items = Array(sorted.dropFirst(start).prefix(limit))
        return GenerationPage(items: items, nextCursor: start + items.count < sorted.count ? items.last?.id.uuidString : nil)
    }

    public func events(_ id: UUID) throws -> AsyncStream<GenerationRecord> {
        let record = try get(id)
        guard (subscribers[id]?.count ?? 0) < 8 else { throw ServiceError(429, "stream_limit", "Too many connections are watching this recording.") }
        let subscriber = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            continuation.yield(record)
            if record.status.isTerminal { continuation.finish(); return }
            subscribers[id, default: [:]][subscriber] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id, subscriber) } }
        }
    }

    public func cancel(_ id: UUID) async throws -> GenerationRecord {
        var record = try get(id)
        guard !record.status.isTerminal else { return record }
        record.status = .cancelled
        record.error = "Recording cancelled."
        record.progress = nil
        record.updatedAt = Date()
        do { try save(record) } catch { publish(record) }
        cleanPartial(id)
        queue.removeAll { $0.id == id }
        if activeID == id, let task = activeTask {
            // Native request cancellation is scoped to this task's operation ID.
            // Wait for cleanup before the worker starts another generation.
            task.cancel()
            await task.value
        }
        return record
    }

    public func recordDelivery(_ id: UUID, receipt: DeliveryReceipt) throws -> GenerationRecord {
        var record = try get(id)
        guard record.importedSource == nil else { throw ServiceError(400, "imported_delivery", "Imported history cannot receive a delivery receipt.") }
        let statuses: Set<String> = ["inserted", "copied", "unconfirmed", "failed", "tested", "listUpdated", "cancelled", "none"]
        guard record.status == .completed, statuses.contains(receipt.status), (receipt.message?.utf8.count ?? 0) <= 4096 else {
            throw ServiceError(400, "invalid_delivery", "A valid delivery receipt requires a completed generation.")
        }
        if let existing = record.delivery {
            guard existing.status == receipt.status, existing.message == receipt.message else { throw ServiceError(409, "delivery_recorded", "This recording already has a delivery outcome.") }
            return record
        }
        record.delivery = DeliveryReceipt(status: receipt.status, message: receipt.message, reportedAt: Date())
        record.updatedAt = Date()
        try save(record)
        return record
    }

    public func delete(_ id: UUID) throws {
        let record = try get(id)
        guard record.status.isTerminal else { throw ServiceError(409, "generation_active", "Cancel or finish a recording before deleting it.") }
        try FileManager.default.removeItem(at: directory(id))
        records[id] = nil
        if let source = record.importedSource, source.provider == "wispr-flow" {
            wisprFlowIndex[source.sourceID] = nil
        }
    }

    public func artifact(_ id: UUID, filename: String) throws -> URL {
        let record = try get(id)
        let allowed = ["metadata.json", "transcript.txt", "inference.wav", "original.wav"]
            + (record.importedSource?.artifactNames.map(\.rawValue) ?? [])
        guard allowed.contains(filename), filename != "inference.wav" || record.inferenceAudio != nil,
              filename != "original.wav" || record.originalAudio != nil,
              filename != "transcript.txt" || record.status == .completed else {
            throw ServiceError(404, "artifact_not_found", "Artifact not found.")
        }
        let url = directory(id).appendingPathComponent(filename)
        let files = FileManager.default
        guard (try? files.attributesOfItem(atPath: directory(id).path)[.type] as? FileAttributeType) == .typeDirectory,
              (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw ServiceError(404, "artifact_not_found", "Artifact not found.")
        }
        return url
    }

    public func knownWisprFlowIDs(_ request: WisprFlowKnownIDsRequest) throws -> WisprFlowKnownIDsResponse {
        guard request.sourceIDs.count <= 10_000 else {
            throw ServiceError(413, "source_id_limit", "Check at most 10,000 source IDs at once.")
        }
        return WisprFlowKnownIDsResponse(knownSourceIDs: request.sourceIDs.filter { wisprFlowIndex[$0] != nil })
    }

    public func beginWisprFlowImport(_ request: WisprFlowImportRequest) throws -> WisprFlowImportSession {
        guard !stopping else { throw ServiceError(503, "server_stopping", "The server is shutting down.") }
        expireImportStages()
        guard importStages.count < 16 else { throw ServiceError(429, "import_limit", "Too many imports are staged.") }
        guard request.createdAt.timeIntervalSince1970 > 0,
              request.createdAt.timeIntervalSince1970 < 4_102_444_800 else {
            throw ServiceError(400, "invalid_source_date", "The source date is outside the supported range.")
        }
        guard request.finalText.utf8.count <= 65_536, request.rawText.utf8.count <= 65_536,
              request.sourceStatus.map({ $0.utf8.count <= 128 && !$0.contains("\0") && !$0.contains("\n") }) ?? true,
              request.variantNames.count <= 32,
              request.variantNames.allSatisfy({ $0.utf8.count <= 64 && !$0.contains("\0") && !$0.contains("\n") }),
              request.durationSeconds.map({ $0.isFinite && $0 >= 0 && $0 <= 86_400 }) ?? true else {
            throw ServiceError(400, "invalid_source_metadata", "The source metadata exceeds its limits or contains invalid values.")
        }
        let names = request.artifacts.map(\.filename)
        guard (1...(WisprFlowArtifactName.allCases.count - 1)).contains(names.count),
              Set(names).count == names.count, names.contains(.sourceJSON), !names.contains(.builtInAudio),
              request.artifacts.allSatisfy({ (1...WisprFlowImportLimits.maximumArtifactBytes).contains($0.byteCount)
                  && Self.validSHA256($0.sha256) }),
              (request.unarchivedArtifacts ?? []).allSatisfy({ $0.filename != .sourceJSON
                  && $0.byteCount > 0 && Self.validSHA256($0.sha256) }) else {
            throw ServiceError(400, "invalid_artifact_manifest", "Supply one valid manifest per allowlisted artifact, including source.json.")
        }
        try requireDiskSpace()
        let id = UUID()
        let directory = stagingDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        importStages[id] = ImportStage(request: request, directory: directory)
        return WisprFlowImportSession(id: id)
    }

    public func uploadWisprFlowArtifact(_ id: UUID, filename: WisprFlowArtifactName, data: Data) throws -> WisprFlowArtifactReceipt {
        guard var stage = importStages[id] else { throw ServiceError(404, "import_not_found", "Import session not found.") }
        guard let manifest = stage.request.artifacts.first(where: { $0.filename == filename }) else {
            throw ServiceError(400, "artifact_unexpected", "This artifact is not in the import manifest.")
        }
        guard data.count == manifest.byteCount, Self.sha256(data) == manifest.sha256 else {
            throw ServiceError(400, "artifact_checksum", "The artifact size or checksum does not match its manifest.")
        }
        switch filename {
        case .sourceJSON:
            guard let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  source["schemaVersion"] as? Int == 1,
                  source["provider"] as? String == "wispr-flow",
                  (source["sourceID"] as? String).flatMap(UUID.init(uuidString:)) == stage.request.sourceID,
                  source["sources"] is [Any] else {
                throw ServiceError(400, "invalid_source_json", "The source artifact must describe this Wispr Flow session.")
            }
            let recorded = try Self.sourceOmissions(source)
            _ = try Self.sourceProvenanceIsPartial(source)
            let recordedKeys = Set(recorded.map { "\($0.filename.rawValue):\($0.byteCount):\($0.sha256)" })
            guard (stage.request.unarchivedArtifacts ?? []).allSatisfy({
                recordedKeys.contains("\($0.filename.rawValue):\($0.byteCount):\($0.sha256)")
            }) else {
                throw ServiceError(400, "invalid_source_json", "Every omitted media digest must be recorded in source.json.")
            }
        case .opusJSON:
            guard (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else {
                throw ServiceError(400, "invalid_opus_json", "Opus source data must be valid JSON.")
            }
        case .sourceWAV:
            guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
                  data.dropFirst(8).prefix(4) == Data("WAVE".utf8) else {
                throw ServiceError(400, "invalid_source_wav", "Source audio must be a RIFF WAVE file.")
            }
        case .screenshotPNG:
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw ServiceError(400, "invalid_screenshot", "Source screenshot must be a PNG file.")
            }
        case .builtInAudio:
            throw ServiceError(400, "unsupported_source_artifact", "Unknown built-in audio bytes can be recorded as omitted, not uploaded.")
        }
        try requireDiskSpace()
        let target = stage.directory.appendingPathComponent(filename.rawValue)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        stage.uploaded.insert(filename)
        stage.touchedAt = Date()
        importStages[id] = stage
        return WisprFlowArtifactReceipt(filename: filename, byteCount: data.count)
    }

    public func completeWisprFlowImport(_ id: UUID) throws -> WisprFlowImportResult {
        guard let stage = importStages[id] else { throw ServiceError(404, "import_not_found", "Import session not found.") }
        let request = stage.request
        guard Set(request.artifacts.map(\.filename)) == stage.uploaded else {
            throw ServiceError(409, "incomplete_import", "Upload every manifest artifact before completing this import.")
        }
        for manifest in request.artifacts {
            let file = stage.directory.appendingPathComponent(manifest.filename.rawValue)
            guard (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
                  let bytes = try? Data(contentsOf: file), bytes.count == manifest.byteCount,
                  Self.sha256(bytes) == manifest.sha256 else {
                throw ServiceError(409, "staged_artifact_changed", "A staged artifact no longer matches its manifest.")
            }
        }
        let incomingHashes = Dictionary(uniqueKeysWithValues: request.artifacts.map { ($0.filename.rawValue, $0.sha256) })
        let sourceHash = incomingHashes[WisprFlowArtifactName.sourceJSON.rawValue]!
        let files = FileManager.default
        if let existingID = wisprFlowIndex[request.sourceID] {
            var record = try get(existingID)
            guard var source = record.importedSource else {
                throw ServiceError(500, "invalid_archive", "The existing source archive is invalid.")
            }
            let conflicts = request.artifacts.filter { manifest in
                manifest.filename != .sourceJSON
                    && source.artifactSHA256[manifest.filename.rawValue].map({ $0 != manifest.sha256 }) ?? false
            }
            let sameArtifacts = request.artifacts.allSatisfy { manifest in
                manifest.filename == .sourceJSON ? source.sourceSHA256 == manifest.sha256
                    : (source.artifactSHA256[manifest.filename.rawValue] == manifest.sha256
                       || (source.artifactSHA256[manifest.filename.rawValue] != nil
                           && source.unarchivedArtifactSHA256?[manifest.filename.rawValue] == manifest.sha256))
            }
            let sameMetadata = (request.finalText.isEmpty || record.finalText == request.finalText)
                && (request.rawText.isEmpty || record.rawText == request.rawText)
                && (request.sourceStatus == nil || source.sourceStatus == request.sourceStatus)
                && (request.durationSeconds == nil || source.durationSeconds == request.durationSeconds)
                && Set(request.variantNames).isSubset(of: Set(source.variantNames))
            if sameArtifacts && sameMetadata {
                let archivedSource = try Data(contentsOf: directory(existingID).appendingPathComponent("source.json"))
                guard let document = try? JSONSerialization.jsonObject(with: archivedSource) as? [String: Any],
                      let provenancePartial = try? Self.sourceProvenanceIsPartial(document) else {
                    throw ServiceError(500, "invalid_archive", "The existing source archive is invalid.")
                }
                try files.removeItem(at: stage.directory)
                importStages[id] = nil
                let unarchived = (source.unarchivedArtifactSHA256 ?? [:]).keys
                    .compactMap(WisprFlowArtifactName.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
                return WisprFlowImportResult(outcome: unarchived.isEmpty && !provenancePartial ? .skipped : .partial,
                                             record: record,
                                             unarchivedArtifactNames: unarchived)
            }
            let earlierDirectory = directory(existingID)
            let oldSource = try Data(contentsOf: earlierDirectory.appendingPathComponent("source.json"))
            var nextSource: Data
            if source.sourceSHA256 != sourceHash {
                let incoming = try Data(contentsOf: stage.directory.appendingPathComponent("source.json"))
                nextSource = try Self.mergedSourceJSON(old: oldSource, incoming: incoming)
                source.sourceSHA256 = sourceHash
            } else {
                nextSource = oldSource
            }
            for manifest in conflicts {
                let filename = manifest.filename.rawValue
                guard let oldHash = source.artifactSHA256[filename] else { continue }
                let earlier = try Data(contentsOf: earlierDirectory.appendingPathComponent(filename))
                guard Self.sha256(earlier) == oldHash else {
                    throw ServiceError(500, "invalid_archive", "An archived source artifact no longer matches its metadata.")
                }
                try writePrivate(earlier, to: stage.directory.appendingPathComponent(filename))
                nextSource = try Self.sourceJSONRecordingConflict(nextSource, filename: filename,
                    archivedSHA256: oldHash, observedSHA256: manifest.sha256, observedByteCount: manifest.byteCount)
            }
            for manifest in request.artifacts where manifest.filename != .sourceJSON {
                guard source.artifactSHA256[manifest.filename.rawValue] == nil else { continue }
                source.artifactSHA256[manifest.filename.rawValue] = manifest.sha256
            }
            let reconciliation = try Self.reconciledSourceJSON(nextSource, archivedHashes: source.artifactSHA256)
            nextSource = reconciliation.data
            source.unarchivedArtifactSHA256 = reconciliation.unarchivedHashes
            try writePrivate(nextSource, to: stage.directory.appendingPathComponent("source.json"))
            source.artifactSHA256[WisprFlowArtifactName.sourceJSON.rawValue] = Self.sha256(nextSource)
            // Assemble the replacement under staging first. The live generation
            // remains untouched until a complete metadata + artifact directory is
            // committed by FileManager's directory replacement.
            for filename in source.artifactNames {
                let old = earlierDirectory.appendingPathComponent(filename.rawValue)
                if !stage.uploaded.contains(filename),
                   (try? files.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType) != .typeRegular {
                    throw ServiceError(500, "invalid_archive", "An archived source artifact is missing.")
                }
            }
            for old in try files.contentsOfDirectory(at: earlierDirectory, includingPropertiesForKeys: nil) {
                let target = stage.directory.appendingPathComponent(old.lastPathComponent)
                guard !files.fileExists(atPath: target.path) else { continue }
                guard try files.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType == .typeRegular else {
                    throw ServiceError(500, "invalid_archive", "Imported artifacts must be regular files.")
                }
                try files.copyItem(at: old, to: target)
            }
            source.sourceStatus = request.sourceStatus ?? source.sourceStatus
            source.durationSeconds = request.durationSeconds ?? source.durationSeconds
            source.variantNames = Array(Set(source.variantNames).union(request.variantNames)).sorted()
            source.artifactNames = source.artifactSHA256.keys.compactMap(WisprFlowArtifactName.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
            record.importedSource = source
            if !request.finalText.isEmpty { record.finalText = request.finalText }
            if !request.rawText.isEmpty { record.rawText = request.rawText }
            record.updatedAt = Date()
            try writePrivate(Data(record.finalText.utf8), to: stage.directory.appendingPathComponent("transcript.txt"))
            let metadata = try InlayAPI.encoder().encode(record)
            guard metadata.count <= Self.maximumMetadataBytes else {
                throw ServiceError(413, "metadata_too_large", "The imported metadata exceeded its 1 MiB storage limit.")
            }
            try writePrivate(metadata, to: stage.directory.appendingPathComponent("metadata.json"))
            _ = try files.replaceItemAt(earlierDirectory, withItemAt: stage.directory)
            publish(record)
            importStages[id] = nil
            let unarchived = reconciliation.unarchivedHashes.keys
                .compactMap(WisprFlowArtifactName.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
            return WisprFlowImportResult(outcome: unarchived.isEmpty && !reconciliation.provenancePartial ? .enriched : .partial,
                                         record: record,
                                         unarchivedArtifactNames: unarchived)
        }

        let recordID = UUID()
        let incomingSource = try Data(contentsOf: stage.directory.appendingPathComponent("source.json"))
        let reconciliation = try Self.reconciledSourceJSON(incomingSource, archivedHashes: incomingHashes)
        try writePrivate(reconciliation.data, to: stage.directory.appendingPathComponent("source.json"))
        var storedHashes = incomingHashes
        storedHashes[WisprFlowArtifactName.sourceJSON.rawValue] = Self.sha256(reconciliation.data)
        var record = GenerationRecord(id: recordID, requestID: request.sourceID,
                                      device: DeviceIdentity(id: "wispr-flow", name: "Wispr Flow"),
                                      mode: .dictation, status: .completed, createdAt: request.createdAt, settings: preferences)
        record.updatedAt = Date()
        record.finalText = request.finalText
        record.rawText = request.rawText
        record.insertionText = ""
        record.previewText = request.finalText
        record.importedSource = ImportedSource(sourceID: request.sourceID, sourceStatus: request.sourceStatus,
                                               importedAt: Date(), variantNames: request.variantNames,
                                               artifactNames: request.artifacts.map(\.filename).sorted { $0.rawValue < $1.rawValue },
                                               durationSeconds: request.durationSeconds, sourceSHA256: sourceHash,
                                               artifactSHA256: storedHashes)
        record.importedSource?.unarchivedArtifactSHA256 = reconciliation.unarchivedHashes
        try writePrivate(Data(record.finalText.utf8), to: stage.directory.appendingPathComponent("transcript.txt"))
        let metadata = try InlayAPI.encoder().encode(record)
        guard metadata.count <= Self.maximumMetadataBytes else {
            throw ServiceError(413, "metadata_too_large", "The imported metadata exceeded its 1 MiB storage limit.")
        }
        try writePrivate(metadata, to: stage.directory.appendingPathComponent("metadata.json"))
        try files.moveItem(at: stage.directory, to: directory(recordID))
        publish(record)
        wisprFlowIndex[request.sourceID] = recordID
        importStages[id] = nil
        let unarchived = reconciliation.unarchivedHashes.keys
            .compactMap(WisprFlowArtifactName.init(rawValue:)).sorted { $0.rawValue < $1.rawValue }
        return WisprFlowImportResult(outcome: unarchived.isEmpty && !reconciliation.provenancePartial ? .imported : .partial,
                                     record: record, unarchivedArtifactNames: unarchived)
    }

    public func cancelWisprFlowImport(_ id: UUID) throws {
        guard let stage = importStages.removeValue(forKey: id) else { return }
        try FileManager.default.removeItem(at: stage.directory)
    }

    private func expireImportStages() {
        let cutoff = Date().addingTimeInterval(-900)
        let stale = importStages.filter { $0.value.touchedAt < cutoff }.map(\.key)
        for id in stale {
            guard let stage = importStages.removeValue(forKey: id) else { continue }
            try? FileManager.default.removeItem(at: stage.directory)
        }
    }

    public func archiveWisprFlowDictionary(_ data: Data) throws -> WisprFlowDictionaryArchiveReceipt {
        guard !data.isEmpty, data.count <= WisprFlowImportLimits.maximumDictionaryBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider"] as? String == "wispr-flow" else {
            throw ServiceError(400, "invalid_dictionary_archive", "Dictionary source data must be valid Wispr Flow JSON within 8 MiB.")
        }
        try requireDiskSpace()
        let root = configuration.dataDirectory.appendingPathComponent("imports/wispr-flow", isDirectory: true)
        let hash = Self.sha256(data)
        let versions = root.appendingPathComponent("dictionary-versions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: versions.path) {
            try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard try FileManager.default.attributesOfItem(atPath: versions.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ServiceError(500, "invalid_storage", "Dictionary archive directories must not be symbolic links.")
        }
        let version = versions.appendingPathComponent("\(hash).json")
        if FileManager.default.fileExists(atPath: version.path) {
            guard try FileManager.default.attributesOfItem(atPath: version.path)[.type] as? FileAttributeType == .typeRegular,
                  Self.sha256(try Data(contentsOf: version)) == hash else {
                throw ServiceError(500, "invalid_dictionary_archive", "An existing dictionary version is invalid.")
            }
        } else {
            try writePrivate(data, to: version)
        }
        try writePrivate(data, to: root.appendingPathComponent("dictionary.json"))
        return WisprFlowDictionaryArchiveReceipt(byteCount: data.count, sha256: hash)
    }

    private func processNext() {
        guard !stopping, activeID == nil else { return }
        guard !queue.isEmpty else { beginWarmup(); return }
        let next = queue.removeFirst()
        activeID = next.id
        activeTask = Task { [weak self] in
            await self?.process(next.id, previous: next.previous)
        }
    }

    private func process(_ id: UUID, previous: DictationContinuation?) async {
        defer {
            if activeID == id {
                activeID = nil
                activeTask = nil
                processNext()
            }
        }
        do {
            try Task.checkCancellation()
            var record = try get(id)
            guard record.status == .queued else { return }
            let settings = record.settings.preferences
            record.status = .transcribing
            try save(record)
            let vocabulary = settings.dictionary.recognitionVocabularyTerms(settings.vocabulary)
            let speech = try await inference.transcribe(directory(id).appendingPathComponent("inference.wav"),
                language: settings.language, vocabularyTerms: vocabulary,
                onProgress: { [weak self] value in Task { await self?.progress(id, value) } })
            try Task.checkCancellation()
            guard try get(id).status == .transcribing else { return }
            record.rawText = speech.text
            record.detectedLanguage = speech.language
            record.recognitionHints = speech.hints
            record.speech = ModelProvenance(modelID: "whisper-large-v3-turbo", modelSHA256: speech.modelSHA256, backend: Self.speechBackend,
                                           engineVersion: speech.engineVersion, processingSeconds: speech.processingSeconds)
            let cleaned = TranscriptCleaner.clean(speech.text)
            let transcript = settings.dictionary.apply(to: cleaned, maximumOutputUTF8Bytes: Self.maximumDictionaryOutputBytes)
            let structured = SpokenListFormatter.format(transcript, context: previous?.list)
            record.formattingRejectionReason = structured.formattingRejectionReason
            record.consumedListControls = structured.consumedControls
            if settings.textCorrectionEnabled, !structured.text.isEmpty { record.status = .proofreading; record.progress = nil; try save(record) }
            let processing = try await proofread(structured.text, settings: settings, dictionaryChanged: cleaned != transcript, language: speech.language)
            try Task.checkCancellation()
            guard !(try get(id)).status.isTerminal else { return }
            record.textProcessing = processing
            if [.applied, .unchanged, .rejected].contains(processing.status) {
                let allTerms = settings.dictionary.vocabularyTerms
                let included = TextCorrectionPolicy.modelHints(allTerms)
                record.proofreadingHints = ModelHintUsage(includedTerms: included,
                    omittedTerms: allTerms.filter { !Set(included).contains($0) })
            }
            if settings.textCorrectionEnabled {
                record.proofreading = ModelProvenance(modelID: "Qwen3-4B-Instruct-2507", modelSHA256: processing.modelSHA256,
                    backend: Self.proofBackend, engineVersion: processing.engineVersion, processingSeconds: processing.processingSeconds)
            }
            let formatted = structured.replacingText(processing.outputText)
            let composition = DictationComposer.compose(formatted, previous: previous)
            record.finalText = formatted.text
            record.insertionText = composition.insertion
            record.previewText = composition.preview
            record.continuation = composition.continuation
            record.status = .completed
            record.updatedAt = Date()
            record.progress = 1
            try Data(record.finalText.utf8).write(to: directory(id).appendingPathComponent("transcript.txt"), options: .atomic)
            try save(record)
        } catch {
            if var record = records[id], !record.status.isTerminal {
                record.status = Task.isCancelled ? .cancelled : .failed
                record.error = error.localizedDescription
                record.updatedAt = Date()
                record.progress = nil
                do { try save(record) } catch { publish(record) }
            }
        }
    }

    private func proofread(_ text: String, settings: ServerPreferences, dictionaryChanged: Bool, language: String) async throws -> TextProcessingRecord {
        let start = Date()
        let terms = settings.dictionary.vocabularyTerms
        func make(_ status: TextProcessingRecord.Status, output: String? = nil, reason: String? = nil,
                  proposedText: String? = nil, verifiedRepairs: [VerifiedTextRepair]? = nil,
                  seconds: Double? = nil, version: String? = nil, sha256: String? = nil) -> TextProcessingRecord {
            TextProcessingRecord(dictionaryTerms: terms, dictionaryChangedText: dictionaryChanged,
                inputText: text, outputText: output ?? text, enabled: settings.textCorrectionEnabled, status: status, reason: reason,
                modelID: settings.textCorrectionEnabled ? "Qwen3-4B-Instruct-2507" : nil, modelSHA256: sha256, engineVersion: version,
                processingSeconds: seconds, wallSeconds: Date().timeIntervalSince(start),
                proposedText: proposedText, verifiedRepairs: verifiedRepairs)
        }
        guard settings.textCorrectionEnabled else { return make(.disabled) }
        guard !text.isEmpty else { return make(.skipped, reason: "No text to correct.") }
        guard text.count <= TextCorrectionPolicy.maximumInputCharacters else { return make(.skipped, reason: "The transcript exceeded the correction length limit.") }
        do {
            let proof = try await inference.correct(text, terms: TextCorrectionPolicy.modelHints(terms), language: language,
                                                    systemPrompt: settings.proofreadingPrompt)
            try Task.checkCancellation()
            let candidate = settings.dictionary.apply(to: proof.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      maximumOutputUTF8Bytes: Self.maximumDictionaryOutputBytes)
            let evaluation = TextCorrectionPolicy.evaluate(original: text, candidate: candidate, preferredTerms: terms)
            if let reason = evaluation.rejectionReason {
                return make(.rejected, reason: reason, proposedText: candidate, verifiedRepairs: evaluation.verifiedRepairs,
                            seconds: proof.processingSeconds, version: proof.engineVersion, sha256: proof.modelSHA256)
            }
            return make(candidate == text ? .unchanged : .applied, output: candidate,
                        proposedText: candidate, verifiedRepairs: evaluation.verifiedRepairs,
                        seconds: proof.processingSeconds, version: proof.engineVersion, sha256: proof.modelSHA256)
        } catch {
            try Task.checkCancellation()
            return make(.failed, reason: error.localizedDescription)
        }
    }

    private func continuation(_ id: UUID?, for record: GenerationRecord) -> DictationContinuation? {
        guard let id else { return nil }
        guard let previous = records[id], previous.device.id == record.device.id, previous.status == .completed,
              Date().timeIntervalSince(previous.updatedAt) >= 0, Date().timeIntervalSince(previous.updatedAt) < 900,
              previous.mode == record.mode,
              previous.mode == .test || ["inserted", "listUpdated"].contains(previous.delivery?.status ?? "") else {
            // Caret context is only a hint. Losing history or its confirmation
            // must never discard the complete new recording.
            return nil
        }
        return previous.continuation
    }

    private func seal(_ upload: Upload, kind: AudioKind, id: UUID) throws -> AudioArtifact {
        let raw = directory(id).appendingPathComponent("\(kind.rawValue).raw")
        let temporary = directory(id).appendingPathComponent("\(kind.rawValue).wav.partial")
        let output = directory(id).appendingPathComponent("\(kind.rawValue).wav")
        try WaveFile.write(rawURL: raw, outputURL: temporary, sampleRate: upload.format.sampleRate, channels: upload.format.channels, float: true)
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try FileManager.default.moveItem(at: temporary, to: output)
        try FileManager.default.removeItem(at: raw)
        return AudioArtifact(filename: output.lastPathComponent, sampleRate: upload.format.sampleRate, channels: upload.format.channels,
                             frameCount: upload.frameCount, byteCount: upload.bytes + 44)
    }

    private func save(_ record: GenerationRecord) throws {
        let data = try InlayAPI.encoder().encode(record)
        guard data.count <= Self.maximumMetadataBytes else {
            throw ServiceError(413, "metadata_too_large", "The generation metadata exceeded its 1 MiB storage limit.")
        }
        try data.write(to: directory(record.id).appendingPathComponent("metadata.json"), options: .atomic)
        publish(record)
    }
    private func stagingDirectory(_ id: UUID) -> URL {
        configuration.dataDirectory.appendingPathComponent("imports/wispr-flow/staging/\(id.uuidString)", isDirectory: true)
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType != .typeRegular {
            throw ServiceError(500, "invalid_storage", "An archive artifact must be a regular file.")
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
    private static func sourceOmissions(_ document: [String: Any]) throws -> [WisprFlowArtifactManifest] {
        guard document["archiveOmissions"] == nil || document["archiveOmissions"] is [[String: Any]] else {
            throw ServiceError(400, "invalid_source_json", "Media omission records must be an array.")
        }
        return try (document["archiveOmissions"] as? [[String: Any]] ?? []).map { entry in
            guard let raw = entry["artifact"] as? String,
                  let filename = WisprFlowArtifactName(rawValue: raw), filename != .sourceJSON,
                  let byteCount = entry["observedByteCount"] as? Int, byteCount > 0,
                  let hash = entry["observedSHA256"] as? String, validSHA256(hash),
                  let status = entry["status"] as? String,
                  status == "not-archived" || status == "archived" else {
                throw ServiceError(400, "invalid_source_json", "Media omission records need a valid name, size, digest, and status.")
            }
            return WisprFlowArtifactManifest(filename: filename, byteCount: byteCount, sha256: hash)
        }
    }
    private static func recordedProvenanceFieldCount(_ document: [String: Any]) throws -> Int {
        guard let sources = document["sources"] as? [[String: Any]] else {
            throw ServiceError(400, "invalid_source_json", "Source provenance rows must be objects.")
        }
        var recordedFieldCount = 0
        for source in sources {
            for key in ["omittedValueCount", "omittedColumnCount"] {
                guard let rawCount = source[key] else { continue }
                guard let count = rawCount as? Int, count >= 0, count <= Int.max - recordedFieldCount else {
                    throw ServiceError(400, "invalid_source_json", "Source row omission counts are invalid.")
                }
                recordedFieldCount += count
            }
            if let digest = source["omittedValuesSHA256"] {
                guard let hash = digest as? String, validSHA256(hash) else {
                    throw ServiceError(400, "invalid_source_json", "Source row omission digests are invalid.")
                }
            }
            for field in (source["values"] as? [String: Any] ?? [:]).values {
                guard let value = field as? [String: Any],
                      value["archiveReason"] as? String == "exceeds-source-json-limit" else { continue }
                guard let type = value["type"] as? String, type == "text" || type == "blob",
                      let byteCount = value["byteCount"] as? Int, byteCount > 0,
                      let digest = value["sha256"] as? String, validSHA256(digest),
                      value["archiveStatus"] as? String == "not-archived",
                      value["value"] == nil, value["base64"] == nil,
                      recordedFieldCount < Int.max else {
                    throw ServiceError(400, "invalid_source_json", "Omitted source values need their size, digest, and reason.")
                }
                recordedFieldCount += 1
            }
        }
        return recordedFieldCount
    }
    private static func sourceProvenanceIsPartial(_ document: [String: Any]) throws -> Bool {
        let countKeys = ["provenanceOmittedFieldCount", "provenanceOmittedSourceCount",
                         "provenanceOmittedMediaVersionCount"]
        let digestKeys = ["provenanceOmittedSourcesSHA256", "provenanceOmittedMediaVersionsSHA256"]
        let recordedFieldCount = try recordedProvenanceFieldCount(document)
        guard let status = document["provenanceStatus"] as? String else {
            guard document["provenanceStatus"] == nil, recordedFieldCount == 0,
                  (countKeys + ["provenanceOmittedColumnCount"] + digestKeys)
                    .allSatisfy({ document[$0] == nil }) else {
                throw ServiceError(400, "invalid_source_json", "Source provenance status and omission counts disagree.")
            }
            return false
        }
        guard status == "partial",
              let fields = document[countKeys[0]] as? Int, fields >= 0,
              let sources = document[countKeys[1]] as? Int, sources >= 0,
              let mediaVersions = document[countKeys[2]] as? Int, mediaVersions >= 0,
              fields > 0 || sources > 0 || mediaVersions > 0,
              fields >= recordedFieldCount,
              document["provenanceOmittedColumnCount"].map({ ($0 as? Int).map({ $0 >= 0 }) ?? false }) ?? true,
              digestKeys.allSatisfy({ key in
                  document[key].map({ ($0 as? String).map(validSHA256) ?? false }) ?? true
              }) else {
            throw ServiceError(400, "invalid_source_json", "Partial source provenance needs valid omission counts and digests.")
        }
        return true
    }
    private static func reconciledSourceJSON(_ data: Data, archivedHashes: [String: String]) throws
        -> (data: Data, unarchivedHashes: [String: String], provenancePartial: Bool) {
        guard var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError(400, "invalid_source_json", "The source archive is invalid.")
        }
        _ = try sourceOmissions(document)
        let provenancePartial = try sourceProvenanceIsPartial(document)
        var missing: [String: String] = [:]
        if var omissions = document["archiveOmissions"] as? [[String: Any]] {
            for index in omissions.indices {
                guard let name = omissions[index]["artifact"] as? String,
                      let digest = omissions[index]["observedSHA256"] as? String else { continue }
                let archived = archivedHashes[name] == digest
                omissions[index]["status"] = archived ? "archived" : "not-archived"
                if !archived && missing[name] == nil { missing[name] = digest }
            }
            document["archiveOmissions"] = omissions
        }
        if var conflicts = document["archiveConflicts"] as? [[String: Any]] {
            for index in conflicts.indices {
                guard let name = conflicts[index]["artifact"] as? String,
                      let digest = conflicts[index]["observedSHA256"] as? String else { continue }
                let archived = archivedHashes[name] == digest
                conflicts[index]["status"] = archived ? "archived" : "not-archived"
                if !archived && missing[name] == nil { missing[name] = digest }
            }
            document["archiveConflicts"] = conflicts
        }
        if var sources = document["sources"] as? [[String: Any]] {
            let media = ["audio": "source.wav", "opusChunks": "opus.json",
                         "screenshot": "screenshot.png", "builtInAudio": "built-in-audio.bin"]
            for sourceIndex in sources.indices {
                guard var values = sources[sourceIndex]["values"] as? [String: Any] else { continue }
                for (column, filename) in media {
                    guard var field = values[column] as? [String: Any],
                          let digest = field["sha256"] as? String else { continue }
                    if archivedHashes[filename] == digest {
                        field["artifact"] = filename
                        field["archiveStatus"] = "archived"
                        field.removeValue(forKey: "archiveReason")
                    } else if field["archiveStatus"] as? String == "not-archived" {
                        field.removeValue(forKey: "artifact")
                    }
                    values[column] = field
                }
                sources[sourceIndex]["values"] = values
            }
            document["sources"] = sources
        }
        let result = try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
        guard result.count <= WisprFlowImportLimits.maximumArtifactBytes else {
            throw ServiceError(413, "source_archive_limit", "The preserved source versions exceeded 8 MiB.")
        }
        return (result, missing, provenancePartial)
    }
    private static func sourceVersionKey(_ source: Any) throws -> String {
        guard var normalized = source as? [String: Any] else {
            throw ServiceError(400, "invalid_source_json", "The source contains an invalid row version.")
        }
        if var values = normalized["values"] as? [String: Any] {
            for column in ["audio", "opusChunks", "screenshot", "builtInAudio"] {
                guard var field = values[column] as? [String: Any] else { continue }
                for key in ["artifact", "archiveStatus", "archiveReason"] {
                    field.removeValue(forKey: key)
                }
                values[column] = field
            }
            normalized["values"] = values
        }
        guard JSONSerialization.isValidJSONObject(normalized) else {
            throw ServiceError(400, "invalid_source_json", "The source contains an invalid row version.")
        }
        return sha256(try JSONSerialization.data(withJSONObject: normalized, options: .sortedKeys))
    }
    private static func mergedSourceJSON(old: Data, incoming: Data) throws -> Data {
        guard let earlier = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
              let newer = try? JSONSerialization.jsonObject(with: incoming) as? [String: Any],
              earlier["provider"] as? String == "wispr-flow",
              (earlier["sourceID"] as? String).flatMap(UUID.init(uuidString:))
                  == (newer["sourceID"] as? String).flatMap(UUID.init(uuidString:)),
              let earlierSources = earlier["sources"] as? [Any],
              let newerSources = newer["sources"] as? [Any] else {
            throw ServiceError(500, "invalid_archive", "The existing source archive cannot be merged.")
        }
        _ = try sourceOmissions(earlier)
        _ = try sourceOmissions(newer)
        var combined: [Any] = []
        var seen = Set<String>()
        for source in earlierSources + newerSources {
            if seen.insert(try sourceVersionKey(source)).inserted { combined.append(source) }
        }
        var combinedOmissions: [[String: Any]] = []
        var seenOmissions = Set<String>()
        for omission in (earlier["archiveOmissions"] as? [[String: Any]] ?? [])
            + (newer["archiveOmissions"] as? [[String: Any]] ?? []) {
            let key = "\(omission["artifact"] as? String ?? ""):\(omission["observedSHA256"] as? String ?? ""):\(omission["sourceName"] as? String ?? ""):\(omission["sourceRowID"] as? Int ?? 0)"
            if seenOmissions.insert(key).inserted { combinedOmissions.append(omission) }
        }
        var merged = earlier
        for (key, value) in newer where key != "sources" && key != "archiveOmissions" { merged[key] = value }
        merged["sources"] = combined
        if !combinedOmissions.isEmpty { merged["archiveOmissions"] = combinedOmissions }
        let earlierPartial = try sourceProvenanceIsPartial(earlier)
        let newerPartial = try sourceProvenanceIsPartial(newer)
        if earlierPartial || newerPartial {
            merged["provenanceStatus"] = "partial"
            let recordedFields = try recordedProvenanceFieldCount(merged)
            for key in ["provenanceOmittedFieldCount", "provenanceOmittedSourceCount",
                        "provenanceOmittedMediaVersionCount", "provenanceOmittedColumnCount"] {
                let minimum = key == "provenanceOmittedFieldCount" ? recordedFields : 0
                let count = max(max(earlier[key] as? Int ?? 0, newer[key] as? Int ?? 0), minimum)
                if key != "provenanceOmittedColumnCount" || count > 0 { merged[key] = count }
            }
            for key in ["provenanceOmittedSourcesSHA256", "provenanceOmittedMediaVersionsSHA256"] {
                if let oldHash = earlier[key] as? String, let newHash = newer[key] as? String,
                   oldHash != newHash { merged.removeValue(forKey: key) }
            }
        }
        _ = try sourceProvenanceIsPartial(merged)
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw ServiceError(400, "invalid_source_json", "The merged source artifact is invalid.")
        }
        let result = try JSONSerialization.data(withJSONObject: merged, options: .sortedKeys)
        guard result.count <= WisprFlowImportLimits.maximumArtifactBytes else {
            throw ServiceError(413, "source_archive_limit", "The preserved source versions exceeded 8 MiB.")
        }
        return result
    }
    private static func sourceJSONRecordingConflict(_ data: Data, filename: String,
                                                    archivedSHA256: String, observedSHA256: String,
                                                    observedByteCount: Int) throws -> Data {
        guard var document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              document["archiveConflicts"] == nil || document["archiveConflicts"] is [[String: Any]] else {
            throw ServiceError(500, "invalid_archive", "Source conflict history is invalid.")
        }
        if var versions = document["sources"] as? [[String: Any]] {
            let mediaColumns = ["audio", "opusChunks", "screenshot", "builtInAudio"]
            for index in versions.indices {
                guard var values = versions[index]["values"] as? [String: Any] else { continue }
                for column in mediaColumns {
                    guard var field = values[column] as? [String: Any],
                          field["artifact"] as? String == filename,
                          field["sha256"] as? String == observedSHA256 else { continue }
                    field.removeValue(forKey: "artifact")
                    field["archiveStatus"] = "not-archived"
                    values[column] = field
                }
                versions[index]["values"] = values
            }
            document["sources"] = versions
        }
        var conflicts = document["archiveConflicts"] as? [[String: Any]] ?? []
        let alreadyRecorded = conflicts.contains {
            $0["artifact"] as? String == filename && $0["observedSHA256"] as? String == observedSHA256
        }
        if !alreadyRecorded {
            conflicts.append(["artifact": filename, "archivedSHA256": archivedSHA256,
                              "observedSHA256": observedSHA256, "observedByteCount": observedByteCount,
                              "status": "not-archived"])
        }
        document["archiveConflicts"] = conflicts
        let result = try JSONSerialization.data(withJSONObject: document, options: .sortedKeys)
        guard result.count <= 8_388_608 else {
            throw ServiceError(413, "source_archive_limit", "The preserved source versions exceeded 8 MiB.")
        }
        return result
    }
    private func publish(_ record: GenerationRecord) {
        records[record.id] = record
        for continuation in subscribers[record.id]?.values ?? [:].values {
            continuation.yield(record)
            if record.status.isTerminal { continuation.finish() }
        }
        if record.status.isTerminal { subscribers[record.id] = nil }
    }

    private func directory(_ id: UUID) -> URL { configuration.dataDirectory.appendingPathComponent("generations/\(id.uuidString)", isDirectory: true) }
    private func removeSubscriber(_ id: UUID, _ subscriber: UUID) { subscribers[id]?[subscriber] = nil }
    private func validLabel(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.count <= limit && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }
    private func requireDiskSpace() throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: configuration.dataDirectory.path)
        if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < 100 * 1024 * 1024 {
            throw ServiceError(507, "storage_full", "The server needs more free disk space before accepting audio.")
        }
    }
    private static func finiteSamples(_ data: Data) -> Bool {
        data.withUnsafeBytes { storage in
            for offset in stride(from: 0, to: storage.count, by: 4) {
                let bits = UInt32(littleEndian: storage.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                if bits & 0x7f80_0000 == 0x7f80_0000 { return false }
            }
            return true
        }
    }
    private func cleanPartial(_ id: UUID) {
        uploads[id] = nil
        for filename in ["inference.raw", "original.raw", "inference.wav.partial", "original.wav.partial"] {
            try? FileManager.default.removeItem(at: directory(id).appendingPathComponent(filename))
        }
    }
    private func progress(_ id: UUID, _ value: Double) {
        guard var record = records[id], record.status == .transcribing, value.isFinite else { return }
        record.progress = min(1, max(0, value))
        records[id] = record
        for continuation in subscribers[id]?.values ?? [:].values { continuation.yield(record) }
    }
    private func heartbeat() {
        for (id, group) in subscribers {
            guard let record = records[id] else { continue }
            for continuation in group.values { continuation.yield(record) }
        }
    }
    private func expireUploads() async {
        let now = Date()
        let expired = uploads.keys.filter { id in
            guard let record = records[id], record.status == .receiving else { return false }
            return now.timeIntervalSince(record.updatedAt) > 45 || now.timeIntervalSince(record.createdAt) > 300
        }
        for id in expired { _ = try? await cancel(id) }
    }
    private func beginWarmup() {
        guard !stopping, !warming, activeID == nil else { return }
        warming = true
        let enabled = preferences.preferences.textCorrectionEnabled
        warmTask = Task { [weak self, inference] in
            // A cancelled take or shutdown can interrupt loading; that is not a failure.
            var failed: Bool?
            do { try await inference.warmUp(proofreadingEnabled: enabled); failed = false }
            catch InferenceError.cancelled {} catch is CancellationError {}
            catch { failed = await !inference.readiness(proofreadingEnabled: false).speechLoaded }
            await self?.warmupFinished(speechLoadFailed: failed)
        }
    }
    private func warmupFinished(speechLoadFailed failed: Bool?) {
        warming = false; warmTask = nil
        if let failed { speechLoadFailed = failed }
    }
    private static var speechBackend: String {
        #if os(macOS)
        return "whisper.cpp/Metal"
        #else
        return "whisper.cpp"
        #endif
    }
    private static var proofBackend: String {
        #if os(macOS)
        return "MLX"
        #else
        return "llama.cpp"
        #endif
    }
}
