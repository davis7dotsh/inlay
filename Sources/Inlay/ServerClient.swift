import Foundation
import InlayAPI

enum ServerClientError: LocalizedError {
    case invalidEndpoint
    case rejected(Int, String, String)
    case invalidResponse
    case disconnected
    case processingTimedOut
    case importArtifactTooLarge(WisprFlowArtifactName, Int)
    case dictionaryArchiveTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The server address is invalid."
        case .rejected(_, let message, _): message
        case .invalidResponse: "The server returned an invalid response."
        case .disconnected: "The server connection was interrupted. Any completed result is available in shared history."
        case .processingTimedOut: "The server is still processing this recording. The result will be ready to copy when it finishes."
        case .importArtifactTooLarge(let name, let bytes):
            "\(name.rawValue) is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), above the 8 MiB source-artifact limit."
        case .dictionaryArchiveTooLarge(let bytes):
            "Wispr Flow dictionary is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), above the 8 MiB archive limit. No dictionary entries were archived."
        }
    }
}

/// A connection is immutable for a take. Editing the configured endpoint cannot
/// redirect a running upload or accidentally send its credential to another host.
struct ServerClient: Sendable {
    let endpoint: URL
    private let token: String
    let session: URLSession
    private let eventsSession: URLSession

    init(endpoint: String, token: String, session: URLSession? = nil) throws {
        self.endpoint = try ServerEndpoint(endpoint).url
        self.token = token
        self.session = session ?? Self.defaultSession
        self.eventsSession = session ?? Self.defaultEventsSession
    }

    private static let defaultSession = makeSession()
    // Long-lived watchers must not occupy every HTTP/1.1 connection used
    // by microphone uploads, generation creation, or server health checks.
    private static let defaultEventsSession = makeSession()

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// `segment` is appended as exactly one percent-encoded path segment, so a
    /// caller-chosen ID containing `/`, `%`, `?`, or `#` cannot change the route.
    func request(path: String, segment: String? = nil, method: String = "GET", body: Data? = nil,
                 contentType: String = "application/json", query: [URLQueryItem] = []) throws -> URLRequest {
        let url = endpoint.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerClientError.invalidEndpoint
        }
        if let segment {
            var allowed = CharacterSet.urlPathAllowed
            // Encoding dots also keeps "." and ".." from becoming dot segments.
            allowed.remove(charactersIn: "/.")
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ServerClientError.invalidEndpoint
            }
            components.percentEncodedPath += "/" + encoded
        }
        if !query.isEmpty { components.queryItems = query }
        guard let target = components.url else { throw ServerClientError.invalidEndpoint }
        var request = URLRequest(url: target)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func json<Response: APIWireModel>(path: String, method: String = "GET", body: Data? = nil,
                                      query: [URLQueryItem] = [], timeout: TimeInterval? = nil) async throws -> Response {
        var request = try request(path: path, method: method, body: body, query: query)
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard data.count <= 16 * 1_024 * 1_024 else { throw ServerClientError.invalidResponse }
        do { return try InlayAPI.decodeWire(Response.self, from: data) }
        catch { throw ServerClientError.invalidResponse }
    }

    func send(path: String, method: String, body: Data? = nil) async throws {
        let (data, response) = try await session.data(for: request(path: path, method: method, body: body))
        try Self.validate(response, data: data)
    }

    static func encode<T: APIWireModel>(_ value: T) throws -> Data {
        try InlayAPI.encodeWire(value)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse else { throw ServerClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            var code = ""
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["message"] as? String ?? object["error"] as? String {
                message = String(detail.prefix(1_000))
                code = object["code"] as? String ?? ""
            } else {
                switch response.statusCode {
                case 401, 403: message = "The server credential was rejected. Update it in Preferences."
                case 409: message = "The recording changed before the request could finish."
                case 429: message = "The server has reached its capacity. Try again shortly."
                case 503: message = "The server is online but its models are not ready."
                default: message = "The server could not complete the request (HTTP \(response.statusCode))."
                }
            }
            throw ServerClientError.rejected(response.statusCode, message, code)
        }
    }
}

/// API redirects are configuration errors. Do not follow them with audio or a
/// credential, even if a reverse proxy accidentally emits one.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension ServerClient {
    func health() async throws -> ServerHealth {
        try await json(path: "v1/health", query: [URLQueryItem(name: "includeRecordingLimit", value: "true")])
    }
    func enroll(device: DeviceIdentity) async throws -> EnrollDeviceResponse {
        try await json(path: "v1/devices/enroll", method: "POST", body: Self.encode(EnrollDeviceRequest(device: device)))
    }
    func devices() async throws -> DeviceList { try await json(path: "v1/devices") }
    func revokeDevice(_ id: String) async throws {
        let (data, response) = try await session.data(for: request(path: "v1/devices", segment: id, method: "DELETE"))
        try Self.validate(response, data: data)
    }
    func closeLegacyEnrollment() async throws -> DeviceList {
        try await json(path: "v1/devices/close-legacy-enrollment", method: "POST")
    }
    func preferences() async throws -> PreferencesSnapshot { try await json(path: "v1/preferences") }
    func storageUsage() async throws -> StorageUsage { try await json(path: "v1/storage") }
    func purgeAudio(_ request: PurgeAudioRequest) async throws -> PurgeAudioResult {
        try await json(path: "v1/storage/purge-audio", method: "POST", body: Self.encode(request))
    }
    func updatePreferences(_ value: PreferencesSnapshot) async throws -> PreferencesSnapshot {
        try await json(path: "v1/preferences", method: "PUT", body: Self.encode(value))
    }
    func history(before cursor: String? = nil, source: String? = nil) async throws -> GenerationPage {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "before", value: cursor)) }
        if let source { query.append(URLQueryItem(name: "source", value: source)) }
        return try await json(path: "v1/generations", query: query)
    }

    func generation(_ id: UUID) async throws -> GenerationRecord {
        let record: GenerationRecord = try await json(path: "v1/generations/\(id)")
        guard record.id == id else { throw ServerClientError.invalidResponse }
        return record
    }
    func create(_ value: CreateGenerationRequest) async throws -> GenerationRecord {
        // A released hold can cancel startup while the server is accepting this
        // request. Keep its response alive so the caller can cancel the returned
        // generation instead of abandoning a receiving session without its ID.
        try await Task {
            let record: GenerationRecord = try await json(
                path: "v1/generations", method: "POST", body: Self.encode(value))
            guard record.requestID == value.requestID, record.device.id == value.device.id, record.mode == value.mode else {
                throw ServerClientError.invalidResponse
            }
            return record
        }.value
    }
    func finish(_ id: UUID, value: FinishGenerationRequest) async throws -> GenerationRecord {
        let body = try Self.encode(value)
        var failures = 0
        while true {
            do {
                // Sealing can sync several GB before replying; a control-request
                // timeout would needlessly replay the same disk operation.
                let record: GenerationRecord = try await json(path: "v1/generations/\(id)/finish", method: "POST", body: body,
                                                              timeout: 120)
                guard record.id == id, record.status != .receiving,
                      record.inferenceAudio?.frameCount == value.inferenceFrames,
                      record.originalAudio?.frameCount == value.originalFrames else { throw ServerClientError.invalidResponse }
                return record
            } catch {
                try Task.checkCancellation()
                // Sealing is idempotent for these exact frame counts: a replay
                // recovers a lost acknowledgement or a delayed first request.
                guard Self.isTransient(error), failures < 3 else { throw error }
                failures += 1
                try await Task.sleep(for: .milliseconds(250 * failures))
            }
        }
    }
    func cancel(_ id: UUID) async throws {
        try await send(path: "v1/generations/\(id)/cancel", method: "POST")
    }
    func reprocess(_ id: UUID) async throws -> GenerationRecord {
        try await json(path: "v1/generations/\(id)/reprocess", method: "POST")
    }
    func delete(_ id: UUID) async throws {
        try await send(path: "v1/generations/\(id)", method: "DELETE")
    }
    func deleteAudio(_ id: UUID) async throws {
        try await send(path: "v1/generations/\(id)/audio", method: "DELETE")
    }
    func delivery(_ id: UUID, receipt: DeliveryReceipt) async throws {
        try await send(path: "v1/generations/\(id)/delivery", method: "POST", body: Self.encode(receipt))
    }

    func audio(_ id: UUID, kind: AudioKind) async throws -> URL {
        let filename = "\(kind.rawValue).wav"
        let (temporary, response) = try await session.download(for: request(path: "v1/generations/\(id)/artifacts/\(filename)"))
        try Self.validate(response)
        let directory = InlayTemporaryDirectory.url.appendingPathComponent("Inlay-remote-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(id)-\(filename)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func events(_ id: UUID, onUpdate: @escaping @Sendable (GenerationRecord) async -> Void) async throws -> GenerationRecord {
        var recoveryFailures = 0
        // Long takes can queue behind each other; a timeout here is not a failure.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3_600))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ServerClientError.processingTimedOut }
            do { return try await readEvents(id, deadline: deadline, onUpdate: onUpdate) }
            catch {
                try Task.checkCancellation()
                guard Self.isTransient(error) else { throw error }
            }
            // A queue can outlive URLSession's request/resource timeout. Read
            // the durable record before reconnecting; a completed result must
            // still be delivered even if its final stream frame was lost.
            do {
                let record = try await generation(id)
                try Task.checkCancellation()
                await onUpdate(record)
                if record.status.isTerminal { return record }
                recoveryFailures = 0
            } catch {
                try Task.checkCancellation()
                guard Self.isTransient(error) else { throw error }
                recoveryFailures += 1
                guard recoveryFailures < 5 else { throw error }
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw ServerClientError.processingTimedOut }
            try await Task.sleep(for: min(Duration.seconds(min(8, 1 << recoveryFailures)), remaining))
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if let error = error as? ServerClientError {
            switch error {
            case .disconnected: return true
            case .rejected(let status, _, _): return [408, 429, 502, 503, 504].contains(status)
            default: return false
            }
        }
        return false
    }

    private func readEvents(_ id: UUID, deadline: ContinuousClock.Instant,
                            onUpdate: @escaping @Sendable (GenerationRecord) async -> Void) async throws -> GenerationRecord {
        var request = try request(path: "v1/generations/\(id)/events")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await eventsSession.bytes(for: request)
        defer { bytes.task.cancel() }
        try Self.validate(response)
        // Parse bounded bytes rather than .lines, whose buffer has no upper limit.
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                guard ContinuousClock.now < deadline else { throw ServerClientError.processingTimedOut }
                if !line.isEmpty {
                    guard let record = try? InlayAPI.decodeWire(GenerationRecord.self, from: line), record.id == id else {
                        throw ServerClientError.invalidResponse
                    }
                    await onUpdate(record)
                    if record.status.isTerminal { return record }
                    line.removeAll(keepingCapacity: true)
                }
            } else {
                guard line.count < 2 * InlayAPI.maximumMetadataBytes else { throw ServerClientError.invalidResponse }
                line.append(byte)
            }
        }
        throw ServerClientError.disconnected
    }

    /// Tails `spool` until capture finishes and every written frame is
    /// acknowledged. While capture runs, transient failures retry without a
    /// deadline: the spool keeps growing on disk, so an outage only delays the
    /// upload. A rejection, or a minute of failures after capture ends, returns
    /// an incomplete outcome; the spool still holds the complete take.
    func upload(_ spool: RecordingSpool, to id: UUID, preserveOriginal: Bool) async throws -> UploadOutcome {
        var inference = SpoolCursor(kind: .inference, url: spool.inferenceURL)
        var original = SpoolCursor(kind: .original, url: spool.originalURL)
        // Fresh recovery uploads start with immutable files. Only those have
        // repeatable full-size chunks from sequence zero (live batches vary).
        let replayFromDisk = spool.snapshot().state == .finished
        var originalRejected = false
        var failingSince: ContinuousClock.Instant?
        var delay: Duration = .milliseconds(500)
        defer { inference.close(); original.close() }
        while true {
            try Task.checkCancellation()
            let snapshot = spool.snapshot()
            if snapshot.state == .cancelled { throw CancellationError() }
            let finished = snapshot.state == .finished
            // Capture can abandon the archival stream mid-take. A prefix
            // uploaded before that happened must not be included in the seal.
            let keepOriginal = preserveOriginal && !originalRejected && snapshot.originalFormat != nil
            if keepOriginal { original.format = snapshot.originalFormat }
            else { original.close() }
            // Batch about half a second while live; catch up a backlog in full chunks.
            let next: (cursor: SpoolCursor, available: Int64, isOriginal: Bool)? = {
                let pendingInference = snapshot.inferenceBytes - inference.sent
                if inference.outstanding != nil || pendingInference >= 32_000 || (finished && pendingInference > 0) {
                    return (inference, pendingInference, false)
                }
                guard keepOriginal else { return nil }
                let pendingOriginal = snapshot.originalBytes - original.sent
                if original.outstanding != nil || pendingOriginal >= 768_000 || (finished && pendingOriginal > 0) {
                    return (original, pendingOriginal, true)
                }
                return nil
            }()
            guard let next else {
                if finished {
                    let originalFrames = keepOriginal && original.sent > 0 ? original.frames : nil
                    return UploadOutcome(finish: FinishGenerationRequest(
                        inferenceFrames: inference.frames, originalFrames: originalFrames), state: .complete)
                }
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            var cursor = next.cursor
            let result = await send(&cursor, available: next.available, to: id, replayFromDisk: replayFromDisk)
            try Task.checkCancellation()
            if next.isOriginal { original = cursor } else { inference = cursor }
            switch result {
            case .sent:
                failingSince = nil
                delay = .milliseconds(500)
            case .omitOriginal:
                originalRejected = true
            case .deferred, .rejected:
                // A read failure, credential change, or bad acknowledgement
                // is not permission to throw the captured original away.
                return UploadOutcome(finish: FinishGenerationRequest(inferenceFrames: inference.frames, originalFrames: nil),
                                     state: result == .deferred ? .deferred : .rejected)
            case .transient:
                // Only a released take gives up, a minute after its first failure.
                if finished {
                    let since = failingSince ?? .now
                    failingSince = since
                    if ContinuousClock.now - since > .seconds(60) {
                        return UploadOutcome(finish: FinishGenerationRequest(inferenceFrames: inference.frames, originalFrames: nil),
                                             state: .deferred)
                    }
                }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(8))
            }
        }
    }

    private enum SendResult { case sent, transient, deferred, rejected, omitOriginal }

    /// Sends the next whole-frame chunk. Retries re-send byte-identical
    /// content at the same sequence, which the server safely replays.
    private func send(_ cursor: inout SpoolCursor, available: Int64, to id: UUID, replayFromDisk: Bool) async -> SendResult {
        guard let format = cursor.format else { return .rejected }
        let frameBytes = Int64(format.channels * 4)
        // A chunk whose acknowledgement was lost must be resent byte for byte,
        // even though more audio has been captured since.
        let count = cursor.outstanding ?? min(available, Int64(InlayAPI.maximumChunkBytes)) / frameBytes * frameBytes
        guard count > 0 else { return .rejected }
        cursor.outstanding = count
        let payload: Data
        do { payload = try cursor.read(count) } catch { return .deferred }
        let sequence = cursor.sequence
        let expectedFrames = (cursor.sent + count) / frameBytes
        let query = [URLQueryItem(name: "sequence", value: String(sequence)),
                     URLQueryItem(name: "sampleRate", value: String(format.sampleRate)),
                     URLQueryItem(name: "channels", value: String(format.channels))]
        do {
            let uploadRequest = try request(path: "v1/generations/\(id)/audio/\(cursor.kind.rawValue)", method: "POST",
                                            body: payload, contentType: "application/octet-stream", query: query)
            let (data, response) = try await session.data(for: uploadRequest)
            try Self.validate(response, data: data)
            let receipt = try InlayAPI.decodeWire(AudioChunkReceipt.self, from: data)
            if receipt.nextSequence != sequence + 1 || receipt.frameCount != expectedFrames {
                // On replay the server verifies this chunk, but acknowledges
                // *all* chunks it already has. Trust a later cursor only if it
                // maps exactly to a possible boundary in this finished spool.
                let totalFrames = (cursor.sent + available) / frameBytes
                let chunkFrames = Int64(InlayAPI.maximumChunkBytes) / frameBytes
                guard replayFromDisk, receipt.nextSequence > sequence + 1,
                      receipt.nextSequence <= (totalFrames - 1) / chunkFrames + 1,
                      receipt.frameCount == min(Int64(receipt.nextSequence) * chunkFrames, totalFrames) else { return .rejected }
            }
            cursor.sequence = receipt.nextSequence
            cursor.sent = receipt.frameCount * frameBytes
            cursor.outstanding = nil
            return .sent
        } catch let ServerClientError.rejected(status, _, code) where cursor.kind == .original
                    && (status == 400 && ["invalid_format", "original_disabled"].contains(code)
                        || status == 413 && code == "recording_limit") {
            // Unsupported originals may be omitted without sacrificing speech.
            return .omitOriginal
        } catch let ServerClientError.rejected(status, _, _) where [401, 403, 507].contains(status) {
            // Fixing credentials or freeing disk doesn't invalidate already
            // accepted bytes. Let the next recovery retry this generation.
            return .deferred
        } catch {
            return Self.isTransient(error) ? .transient : .rejected
        }
    }
}

struct UploadOutcome: Sendable {
    enum State: Sendable { case complete, deferred, rejected }
    let finish: FinishGenerationRequest
    let state: State
    var complete: Bool { state == .complete }
    /// Transient failures do not invalidate bytes already uploaded from a
    /// finished spool. Reuse its existing request ID and deterministic chunks.
    var canResume: Bool { state == .deferred }
}

/// Reads one spool stream from the position the server has acknowledged.
private struct SpoolCursor {
    let kind: AudioKind
    let url: URL
    var format: AudioStreamFormat?
    var sent: Int64 = 0
    var sequence = 0
    /// Byte count of the chunk sent at `sequence` and not yet acknowledged.
    var outstanding: Int64?
    private var handle: FileHandle?

    init(kind: AudioKind, url: URL) {
        self.kind = kind
        self.url = url
        if kind == .inference { format = AudioStreamFormat(sampleRate: 16_000, channels: 1) }
    }

    var frames: Int64 { format.map { sent / Int64($0.channels * 4) } ?? 0 }

    mutating func read(_ count: Int64) throws -> Data {
        if handle == nil { handle = try FileHandle(forReadingFrom: url) }
        guard let handle else { throw ServerClientError.invalidResponse }
        try handle.seek(toOffset: UInt64(sent))
        guard let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else {
            throw ServerClientError.invalidResponse
        }
        return data
    }

    mutating func close() {
        try? handle?.close()
        handle = nil
    }
}
