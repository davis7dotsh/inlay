import CryptoKit
import Foundation
import InlayAPI

enum ServerClientError: LocalizedError {
    case invalidEndpoint
    case rejected(Int, String)
    case invalidResponse
    case disconnected
    case uploadBacklog
    case importArtifactTooLarge(WisprFlowArtifactName, Int)
    case dictionaryArchiveTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "The server address is invalid."
        case .rejected(_, let message): message
        case .invalidResponse: "The server returned an invalid response."
        case .disconnected: "The server connection was interrupted. Any completed result is available in shared history."
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
    private let session: URLSession

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

    func request(path: String, method: String = "GET", body: Data? = nil,
                 contentType: String = "application/json", query: [URLQueryItem] = []) throws -> URLRequest {
        let url = endpoint.appendingPathComponent(path)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerClientError.invalidEndpoint
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

    private static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse else { throw ServerClientError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message: String
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = object["message"] as? String ?? object["error"] as? String {
                message = String(detail.prefix(1_000))
            } else {
                switch response.statusCode {
                case 401, 403: message = "The server credential was rejected. Update it in Preferences."
                case 409: message = "The recording changed before the request could finish."
                case 429: message = "The server has reached its capacity. Try again shortly."
                case 503: message = "The server is online but its models are not ready."
                default: message = "The server could not complete the request (HTTP \(response.statusCode))."
                }
            }
            throw ServerClientError.rejected(response.statusCode, message)
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
    func preferences() async throws -> PreferencesSnapshot { try await json(path: "v1/preferences") }
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

    func knownWisprFlowSourceIDs(_ sourceIDs: [UUID]) async throws -> Set<UUID> {
        var known = Set<UUID>()
        // The server's 256 KiB JSON body limit is tighter than its 10,000-ID limit.
        for start in stride(from: 0, to: sourceIDs.count, by: 5_000) {
            let batch = Array(sourceIDs[start..<min(start + 5_000, sourceIDs.count)])
            let input = WisprFlowKnownIDsRequest(sourceIDs: batch)
            let result: WisprFlowKnownIDsResponse = try await json(
                path: "v1/imports/wispr-flow/known", method: "POST", body: Self.encode(input))
            known.formUnion(result.knownSourceIDs)
        }
        return known
    }

    func beginWisprFlowImport(_ value: WisprFlowImportRequest) async throws -> WisprFlowImportSession {
        try await json(path: "v1/imports/wispr-flow", method: "POST", body: Self.encode(value))
    }

    func uploadWisprFlowArtifact(_ url: URL, filename: WisprFlowArtifactName,
                                 contentType: String, to importID: UUID) async throws -> WisprFlowArtifactReceipt {
        let upload = try request(path: "v1/imports/wispr-flow/\(importID)/artifacts/\(filename.rawValue)",
                                 method: "PUT", contentType: contentType)
        let (data, response) = try await session.upload(for: upload, fromFile: url)
        try Self.validate(response, data: data)
        return try InlayAPI.decodeWire(WisprFlowArtifactReceipt.self, from: data)
    }

    func completeWisprFlowImport(_ importID: UUID) async throws -> WisprFlowImportResult {
        try await json(path: "v1/imports/wispr-flow/\(importID)/complete", method: "POST")
    }

    func cancelWisprFlowImport(_ importID: UUID) async throws {
        try await send(path: "v1/imports/wispr-flow/\(importID)", method: "DELETE")
    }

    func archiveWisprFlowDictionary(_ url: URL) async throws -> WisprFlowDictionaryArchiveReceipt {
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...WisprFlowImportLimits.maximumDictionaryBytes).contains(bytes) else {
            throw ServerClientError.dictionaryArchiveTooLarge(bytes)
        }
        let upload = try request(path: "v1/imports/wispr-flow/dictionary", method: "PUT", contentType: "application/json")
        let (data, response) = try await session.upload(for: upload, fromFile: url)
        try Self.validate(response, data: data)
        return try InlayAPI.decodeWire(WisprFlowDictionaryArchiveReceipt.self, from: data)
    }

    static func wisprFlowArtifactManifest(filename: WisprFlowArtifactName, url: URL) throws -> WisprFlowArtifactManifest {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...WisprFlowImportLimits.maximumArtifactBytes).contains(size) else {
            throw ServerClientError.importArtifactTooLarge(filename, size)
        }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hash = SHA256()
        var byteCount = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk)
            byteCount += chunk.count
        }
        let sha256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return WisprFlowArtifactManifest(filename: filename, byteCount: byteCount, sha256: sha256)
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
    func retry(_ id: UUID) async throws -> GenerationRecord {
        try await json(path: "v1/generations/\(id)/retry", method: "POST")
    }
    func delete(_ id: UUID) async throws {
        try await send(path: "v1/generations/\(id)", method: "DELETE")
    }
    func delivery(_ id: UUID, receipt: DeliveryReceipt) async throws {
        try await send(path: "v1/generations/\(id)/delivery", method: "POST", body: Self.encode(receipt))
    }

    func audio(_ id: UUID, kind: AudioKind) async throws -> URL {
        let filename = "\(kind.rawValue).wav"
        let (temporary, response) = try await session.download(for: request(path: "v1/generations/\(id)/artifacts/\(filename)"))
        try Self.validate(response)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Inlay-remote-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(id)-\(filename)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func wisprFlowArtifact(_ id: UUID, filename: WisprFlowArtifactName) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(path: "v1/generations/\(id)/artifacts/\(filename.rawValue)"))
        try Self.validate(response)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Inlay-remote-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(id)-\(filename.rawValue)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func events(_ id: UUID, onUpdate: @escaping @Sendable (GenerationRecord) async -> Void) async throws -> GenerationRecord {
        var recoveryFailures = 0
        while true {
            try Task.checkCancellation()
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
            try await Task.sleep(for: .seconds(min(8, 1 << recoveryFailures)))
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
            case .rejected(let status, _): return [408, 429, 502, 503, 504].contains(status)
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
                preserveOriginal: Bool) async throws -> FinishGenerationRequest {
        var inference = UploadBuffer(kind: .inference)
        var original = UploadBuffer(kind: .original)
        for try await chunk in stream {
            try Task.checkCancellation()
            switch chunk.kind {
            case .normalized: try inference.append(chunk)
            case .original:
                guard preserveOriginal else { throw ServerClientError.invalidResponse }
                try original.append(chunk)
            }
            // Batch about half a second of samples, overlapping transfer with the
            // microphone while keeping HTTP overhead and memory bounded.
            if inference.data.count >= 32_000 {
                try await flush(&inference, to: id)
                try await flush(&original, to: id)
            }
            if original.data.count >= 768_000 { try await flush(&original, to: id) }
        }
        try await flush(&inference, to: id)
        try await flush(&original, to: id)
        return FinishGenerationRequest(inferenceFrames: inference.frames,
                                       originalFrames: preserveOriginal ? original.frames : nil)
    }

    private func flush(_ buffer: inout UploadBuffer, to id: UUID) async throws {
        guard !buffer.data.isEmpty, let format = buffer.format else { return }
        let query = [URLQueryItem(name: "sequence", value: String(buffer.sequence)),
                     URLQueryItem(name: "sampleRate", value: String(format.sampleRate)),
                     URLQueryItem(name: "channels", value: String(format.channels))]
        let request = try request(path: "v1/generations/\(id)/audio/\(buffer.kind.rawValue)", method: "POST",
                                  body: buffer.data, contentType: "application/octet-stream", query: query)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        let receipt = try InlayAPI.decodeWire(AudioChunkReceipt.self, from: data)
        guard receipt.nextSequence == buffer.sequence + 1, receipt.frameCount == buffer.frames else {
            throw ServerClientError.invalidResponse
        }
        buffer.sequence = receipt.nextSequence
        buffer.data.removeAll(keepingCapacity: true)
    }
}

private struct UploadBuffer {
    let kind: AudioKind
    var data = Data()
    var format: AudioStreamFormat?
    var frames: Int64 = 0
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
