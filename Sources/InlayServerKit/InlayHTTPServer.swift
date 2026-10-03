import Foundation
import Hummingbird
import InlayAPI

public enum InlayHTTPServer {
    public static func run(configuration: ServerConfiguration) async throws {
        let directoryLock = try DataDirectoryLock(directory: configuration.dataDirectory)
        defer { directoryLock.release() }
        let service = try GenerationService(configuration: configuration)
        let router = makeRouter(service: service, token: configuration.token)
        let app = Application(router: router,
            configuration: .init(address: .hostname(configuration.host, port: configuration.port), serverName: configuration.development ? "Inlay Dev" : "Inlay"))
        await service.start()
        do { try await app.runService() }
        catch { await service.shutdown(); throw error }
        await service.shutdown()
    }

    public static func makeRouter(service: GenerationService, token: String? = nil) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: ServerMiddleware(token: token))
        router.get("/v1/health") { _, _ in try json(await service.health()) }
        router.get("/v1/preferences") { _, _ in try json(await service.getPreferences()) }
        router.put("/v1/preferences") { request, _ in
            let update = try await decode(PreferencesSnapshot.self, request: request)
            return try json(await service.updatePreferences(update))
        }
        router.post("/v1/generations") { request, _ in
            let input = try await decode(CreateGenerationRequest.self, request: request)
            return try json(await service.create(input), status: .created)
        }
        router.post("/v1/imports/wispr-flow/known") { request, _ in
            let input = try await decode(WisprFlowKnownIDsRequest.self, request: request)
            return try json(await service.knownWisprFlowIDs(input))
        }
        router.put("/v1/imports/wispr-flow/dictionary") { request, _ in
            let buffer = try await request.body.collect(upTo: WisprFlowImportLimits.maximumDictionaryBytes)
            return try json(await service.archiveWisprFlowDictionary(Data(buffer.readableBytesView)))
        }
        router.post("/v1/imports/wispr-flow") { request, _ in
            let input = try await decode(WisprFlowImportRequest.self, request: request)
            return try json(await service.beginWisprFlowImport(input), status: .created)
        }
        router.put("/v1/imports/wispr-flow/:id/artifacts/:filename") { request, context in
            guard let raw = context.parameters.get("filename"), let filename = WisprFlowArtifactName(rawValue: raw) else {
                throw ServiceError(400, "invalid_source_artifact", "Choose an allowlisted source artifact.")
            }
            let buffer = try await request.body.collect(upTo: 8_388_608)
            return try json(await service.uploadWisprFlowArtifact(identifier(context), filename: filename,
                                                                 data: Data(buffer.readableBytesView)))
        }
        router.post("/v1/imports/wispr-flow/:id/complete") { _, context in
            try json(await service.completeWisprFlowImport(identifier(context)))
        }
        router.delete("/v1/imports/wispr-flow/:id") { _, context in
            try await service.cancelWisprFlowImport(identifier(context))
            return Response(status: .noContent)
        }
        router.get("/v1/generations") { request, _ in
            let limit: Int
            if let raw = request.uri.queryParameters.get("limit") {
                guard let value = Int(raw) else { throw ServiceError(400, "invalid_limit", "Invalid history page size.") }
                limit = value
            } else { limit = 50 }
            return try json(await service.history(limit: limit, before: request.uri.queryParameters.get("before"),
                                                  source: request.uri.queryParameters.get("source")))
        }
        router.get("/v1/generations/:id") { _, context in try json(await service.get(identifier(context))) }
        router.post("/v1/generations/:id/audio/:kind") { request, context in
            let id = try identifier(context)
            guard let rawKind = context.parameters.get("kind"), let kind = AudioKind(rawValue: rawKind),
                  let sequence = request.uri.queryParameters.get("sequence", as: Int.self),
                  let rate = request.uri.queryParameters.get("sampleRate", as: Int.self),
                  let channels = request.uri.queryParameters.get("channels", as: Int.self) else {
                throw ServiceError(400, "invalid_audio_parameters", "Supply audio kind, sequence, sampleRate and channels.")
            }
            let buffer = try await request.body.collect(upTo: InlayAPI.maximumChunkBytes)
            let data = Data(buffer.readableBytesView)
            return try json(await service.appendAudio(id, kind: kind, sequence: sequence,
                                                     format: AudioStreamFormat(sampleRate: rate, channels: channels), data: data))
        }
        router.post("/v1/generations/:id/finish") { request, context in
            let input = try await decode(FinishGenerationRequest.self, request: request)
            return try json(await service.finish(identifier(context), request: input), status: .accepted)
        }
        router.post("/v1/generations/:id/cancel") { _, context in try json(await service.cancel(identifier(context))) }
        router.post("/v1/generations/:id/delivery") { request, context in
            let input = try await decode(DeliveryReceipt.self, request: request)
            return try json(await service.recordDelivery(identifier(context), receipt: input))
        }
        router.get("/v1/generations/:id/events") { _, context in
            let stream = try await service.events(identifier(context))
            return Response(status: .ok, headers: [.contentType: "application/x-ndjson", .cacheControl: "no-store"], body: .init { writer in
                for await record in stream {
                    var data = try InlayAPI.encoder().encode(record)
                    data.append(0x0a)
                    try await writer.write(ByteBuffer(bytes: data))
                }
                try await writer.finish(nil)
            })
        }
        router.get("/v1/generations/:id/artifacts/:filename") { _, context in
            guard let filename = context.parameters.get("filename") else { throw ServiceError(404, "artifact_not_found", "Artifact not found.") }
            let path = try await service.artifact(identifier(context), filename: filename)
            let body = try await FileIO().loadFile(path: path.path, context: context)
            let type = filename.hasSuffix(".wav") ? "audio/wav" : (filename.hasSuffix(".png") ? "image/png" :
                (filename.hasSuffix(".json") ? "application/json" : "text/plain; charset=utf-8"))
            return Response(status: .ok, headers: [.contentType: type, .cacheControl: "no-store"], body: body)
        }
        router.delete("/v1/generations/:id") { _, context in
            try await service.delete(identifier(context))
            return Response(status: .noContent)
        }
        return router
    }

    private static func identifier(_ context: BasicRequestContext) throws -> UUID {
        guard let raw = context.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw ServiceError(400, "invalid_id", "A recording ID must be a UUID.")
        }
        return id
    }

    private static func decode<T: Decodable>(_ type: T.Type, request: Request) async throws -> T {
        let buffer = try await request.body.collect(upTo: 262_144)
        do { return try InlayAPI.decoder().decode(type, from: Data(buffer.readableBytesView)) }
        catch { throw ServiceError(400, "invalid_json", "The request did not contain valid \(String(describing: type)) JSON.") }
    }

    fileprivate static func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response {
        Response(status: status, headers: [.contentType: "application/json; charset=utf-8", .cacheControl: "no-store"],
                 body: .init(byteBuffer: ByteBuffer(bytes: try InlayAPI.encoder().encode(value))))
    }
}

private struct ServerMiddleware: RouterMiddleware {
    typealias Context = BasicRequestContext
    let token: String?

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            if token == nil {
                guard Self.isLoopbackAuthority(request.head.authority ?? request.headers[.init("Host")!]),
                      request.headers[.init("Host")!].map({ Self.isLoopbackAuthority($0) }) ?? true else {
                    throw ServiceError(403, "host_rejected", "Tokenless connections must address localhost directly.")
                }
            }
            if request.uri.path != "/v1/health", let token {
                guard let authorization = request.headers[.authorization], Self.equal(authorization, "Bearer \(token)") else {
                    throw ServiceError(401, "unauthorized", "Connect with the server's access token.")
                }
            }
            // A browser page must not use a tokenless localhost API through CORS
            // or a simple cross-origin POST. Native clients send no Origin header.
            if request.headers[.origin] != nil { throw ServiceError(403, "origin_rejected", "Browser origins are not supported by this native-client API.") }
            return try await next(request, context)
        } catch let error as ServiceError {
            return try InlayHTTPServer.json(APIErrorResponse(code: error.code, message: error.message), status: .init(code: error.status))
        } catch let error as HTTPError {
            return try InlayHTTPServer.json(APIErrorResponse(code: "http_\(error.status.code)", message: error.body ?? error.status.reasonPhrase), status: error.status)
        } catch let error as any HTTPResponseError {
            return try InlayHTTPServer.json(APIErrorResponse(code: "http_\(error.status.code)", message: error.status.reasonPhrase), status: error.status)
        } catch {
            // Filesystem paths and framework diagnostics are never returned as
            // generic HTTP failures; there is no transcript/body access logging.
            context.logger.error("Inlay request failed", metadata: ["errorType": .string(String(describing: type(of: error)))])
            return try InlayHTTPServer.json(APIErrorResponse(code: "internal_error", message: "The server could not complete this request."), status: .internalServerError)
        }
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = a.count ^ b.count
        for index in 0..<max(a.count, b.count) {
            difference |= Int((index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0))
        }
        return difference == 0
    }

    private static func isLoopbackAuthority(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let authority = value.lowercased()
        let port: Substring?
        if authority.hasPrefix("[::1]") {
            let suffix = authority.dropFirst(5)
            if suffix.isEmpty { return true }
            guard suffix.first == ":" else { return false }
            port = suffix.dropFirst()
        } else {
            let parts = authority.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let host = parts.first, host == "localhost" || host == "127.0.0.1" else { return false }
            port = parts.count == 2 ? parts[1] : nil
        }
        guard let port else { return true }
        return !port.isEmpty && port.utf8.allSatisfy { (48...57).contains($0) } && Int(port).map { (1...65535).contains($0) } == true
    }
}
