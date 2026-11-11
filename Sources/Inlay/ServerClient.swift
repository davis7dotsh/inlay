import CryptoKit
import Foundation
import InlayAPI

enum ServerClientError: LocalizedError {
    case invalidEndpoint
    case rejected(Int, String, String)
    case invalidResponse
    case disconnected
    case processingTimedOut
    case uploadBacklog
    case importArtifactTooLarge(WisprFlowArtifactName, Int)
    case dictionaryArchiveTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The server address is invalid."
        case .rejected(_, let message, _): message
        case .invalidResponse: "The server returned an invalid response."
        case .disconnected: "The server connection was interrupted. Any completed result is available in shared history."
        case .processingTimedOut: "The server is still processing this recording. The result will be ready to copy when it finishes."
        case .uploadBacklog: "The connection cannot keep up with the microphone. This recording was stopped."
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

    init(endpoint: String, token: String, session: URLSession? = nil) throws {
        self.endpoint = try ServerEndpoint(endpoint).url
        self.token = token
        self.session = session ?? Self.defaultSession
    }

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

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

    func json<Response: APIWireModel>(path: String, method: String = "GET", body: Data? = nil) async throws -> Response {
        let (data, response) = try await session.data(for: request(path: path, method: method, body: body))
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

/// The callback never blocks the capture queue. Its bounded queue fails the take
/// if a connection falls behind, instead of building a hidden offline backlog.
final class AudioChunkPipe: @unchecked Sendable {
    let stream: AsyncThrowingStream<CapturedAudioChunk, Error>
    private let continuation: AsyncThrowingStream<CapturedAudioChunk, Error>.Continuation
    private let onFailure: (@Sendable (Error) -> Void)?

    init(onFailure: (@Sendable (Error) -> Void)? = nil) {
        self.onFailure = onFailure
        let pair = AsyncThrowingStream<CapturedAudioChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        stream = pair.stream
        continuation = pair.continuation
    }

    func append(_ chunk: CapturedAudioChunk) {
        if case .dropped = continuation.yield(chunk) {
            continuation.finish(throwing: ServerClientError.uploadBacklog)
            onFailure?(ServerClientError.uploadBacklog)
        }
    }

    func finish() { continuation.finish() }
    func cancel() { continuation.finish(throwing: CancellationError()) }
}

extension ServerClient {
    func health() async throws -> ServerHealth { try await json(path: "v1/health") }
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
        let (data, response) = try await session.data(for: request(path: "v1/generations", query: query))
        try Self.validate(response, data: data)
        guard data.count <= 16 * 1_024 * 1_024 else { throw ServerClientError.invalidResponse }
        return try InlayAPI.decodeWire(GenerationPage.self, from: data)
    }

    func generation(_ id: UUID) async throws -> GenerationRecord { try await json(path: "v1/generations/\(id)") }
    func create(_ value: CreateGenerationRequest) async throws -> GenerationRecord {
        // A released hold can cancel startup while the server is accepting this
        // request. Keep its response alive so the caller can cancel the returned
        // generation instead of abandoning a receiving session without its ID.
        try await Task {
            let record: GenerationRecord = try await json(
                path: "v1/generations", method: "POST", body: Self.encode(value))
            return record
        }.value
    }
    func finish(_ id: UUID, value: FinishGenerationRequest) async throws -> GenerationRecord {
        let body = try Self.encode(value)
        var failures = 0
        while true {
            do { return try await json(path: "v1/generations/\(id)/finish", method: "POST", body: body) }
            catch {
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ServerClientError.processingTimedOut }
            do { return try await readEvents(id, onUpdate: onUpdate) }
            catch {
                try Task.checkCancellation()
                guard Self.isTransient(error) else { throw error }
            }
            // A queue can outlive URLSession's request/resource timeout. Read
            // the durable record before reconnecting; a completed result must
            // still be delivered even if its final stream frame was lost.
            do {
                let record = try await generation(id)
                guard record.id == id else { throw ServerClientError.invalidResponse }
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

    private func readEvents(_ id: UUID, onUpdate: @escaping @Sendable (GenerationRecord) async -> Void) async throws -> GenerationRecord {
        var request = try request(path: "v1/generations/\(id)/events")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)
        // Parse bounded bytes rather than .lines, whose buffer has no upper limit.
        var line = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            if byte == 10 {
                if !line.isEmpty {
                    guard let record = try? InlayAPI.decodeWire(GenerationRecord.self, from: line), record.id == id else {
                        throw ServerClientError.invalidResponse
                    }
                    await onUpdate(record)
                    if record.status.isTerminal { return record }
                    line.removeAll(keepingCapacity: true)
                }
            } else {
                guard line.count < 2 * 1_024 * 1_024 else { throw ServerClientError.invalidResponse }
                line.append(byte)
            }
        }
        throw ServerClientError.disconnected
    }

    func upload(_ stream: AsyncThrowingStream<CapturedAudioChunk, Error>, to id: UUID,
                preserveOriginal: Bool) async throws -> UploadOutcome {
        var inference = UploadBuffer(kind: .inference)
        var original = UploadBuffer(kind: .original)
        var keepOriginal = preserveOriginal
        func outcome(complete: Bool) -> UploadOutcome {
            let originalFrames = complete ? original.frames : original.acknowledgedFrames
            // The failed inference chunk may have reached the server with only its
            // acknowledgement lost. Its original-audio interval was never sent, so
            // that count seals without the archival copy.
            let fallback = !complete && inference.frames > inference.acknowledgedFrames
                ? FinishGenerationRequest(inferenceFrames: inference.frames, originalFrames: nil) : nil
            return UploadOutcome(finish: FinishGenerationRequest(
                inferenceFrames: complete ? inference.frames : inference.acknowledgedFrames,
                originalFrames: keepOriginal && originalFrames > 0 ? originalFrames : nil),
                complete: complete, fallback: fallback)
        }
        func flushOriginal() async throws {
            guard keepOriginal else { return }
            if try await flush(&original, to: id) == false {
                // Archival copy failed; never lose the inference take over it.
                keepOriginal = false
                original = UploadBuffer(kind: .original)
            }
        }
        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                switch chunk.kind {
                case .normalized: try inference.append(chunk)
                case .original:
                    guard preserveOriginal else { throw ServerClientError.invalidResponse }
                    if keepOriginal,
                       !OriginalAudioPolicy.isArchivable(sampleRate: chunk.sampleRate, channels: chunk.channels) {
                        keepOriginal = false
                    }
                    if keepOriginal { try original.append(chunk) }
                }
                // Batch about half a second of samples, overlapping transfer with the
                // microphone while keeping HTTP overhead and memory bounded.
                if inference.data.count >= 32_000 {
                    guard try await flush(&inference, to: id) else { return outcome(complete: false) }
                    try await flushOriginal()
                }
                if original.data.count >= 768_000 { try await flushOriginal() }
            }
        } catch ServerClientError.uploadBacklog {
            // The microphone outran a stalled connection. Keep everything
            // captured before the overflow as an interrupted take.
            guard try await flush(&inference, to: id) else { return outcome(complete: false) }
            try await flushOriginal()
            return outcome(complete: false)
        }
        guard try await flush(&inference, to: id) else { return outcome(complete: false) }
        try await flushOriginal()
        return outcome(complete: true)
    }

    /// Returns false when the flush ultimately failed (non-transient error or
    /// the 60 s retry deadline passed); throws only on cancellation. Retries
    /// re-send byte-identical content, which the server safely replays.
    private func flush(_ buffer: inout UploadBuffer, to id: UUID) async throws -> Bool {
        guard !buffer.data.isEmpty, let format = buffer.format else { return true }
        let payload = buffer.data
        let sequence = buffer.sequence
        let expectedFrames = buffer.frames
        let query = [URLQueryItem(name: "sequence", value: String(sequence)),
                     URLQueryItem(name: "sampleRate", value: String(format.sampleRate)),
                     URLQueryItem(name: "channels", value: String(format.channels))]
        let uploadRequest = try request(path: "v1/generations/\(id)/audio/\(buffer.kind.rawValue)", method: "POST",
                                        body: payload, contentType: "application/octet-stream", query: query)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var delay: Duration = .milliseconds(500)
        while true {
            do {
                let (data, response) = try await session.data(for: uploadRequest)
                try Self.validate(response, data: data)
                let receipt = try InlayAPI.decodeWire(AudioChunkReceipt.self, from: data)
                guard receipt.nextSequence == sequence + 1, receipt.frameCount == expectedFrames else {
                    throw ServerClientError.invalidResponse
                }
                buffer.sequence = receipt.nextSequence
                buffer.acknowledgedFrames = receipt.frameCount
                buffer.data.removeAll(keepingCapacity: true)
                return true
            } catch {
                try Task.checkCancellation()
                guard Self.isTransient(error), ContinuousClock.now < deadline else { return false }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(8))
            }
        }
    }
}

struct UploadOutcome: Sendable {
    let finish: FinishGenerationRequest
    let complete: Bool
    /// Seal counts to try when `finish` is rejected as incomplete audio.
    let fallback: FinishGenerationRequest?
}

private struct UploadBuffer {
    let kind: AudioKind
    var data = Data()
    var format: AudioStreamFormat?
    var frames: Int64 = 0
    var acknowledgedFrames: Int64 = 0
    var sequence = 0

    mutating func append(_ chunk: CapturedAudioChunk) throws {
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              chunk.sampleRate <= 192_000, chunk.channels > 0, chunk.channels <= 8,
              chunk.data.count % (chunk.channels * 4) == 0 else { throw ServerClientError.invalidResponse }
        let incoming = AudioStreamFormat(sampleRate: Int(chunk.sampleRate), channels: chunk.channels)
        guard format == nil || format == incoming else { throw ServerClientError.invalidResponse }
        guard data.count + chunk.data.count <= InlayAPI.maximumChunkBytes else { throw ServerClientError.uploadBacklog }
        format = incoming
        data.append(chunk.data)
        frames += Int64(chunk.data.count / (chunk.channels * 4))
    }
}
