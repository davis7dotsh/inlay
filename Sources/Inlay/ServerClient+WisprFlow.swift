import CryptoKit
import Foundation
import InlayAPI

// Wispr Flow import endpoints, isolated with the migration bridge (Batch 8).
extension ServerClient {
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
    func wisprFlowArtifact(_ id: UUID, filename: WisprFlowArtifactName) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(path: "v1/generations/\(id)/artifacts/\(filename.rawValue)"))
        try Self.validate(response)
        let directory = InlayTemporaryDirectory.url.appendingPathComponent("Inlay-remote-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("\(id)-\(filename.rawValue)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

}
