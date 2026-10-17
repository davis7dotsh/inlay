import CryptoKit
import Foundation

public struct SpeechModel: Sendable {
    public let id: String
    public let name: String
    public let filename: String
    public let byteCount: Int64
    public let sha256: String
    public let downloadURL: URL

    public init(id: String, name: String, filename: String, byteCount: Int64, sha256: String, downloadURL: URL) {
        self.id = id
        self.name = name
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.downloadURL = downloadURL
    }

    // Pinned upstream revision and LFS digest, not a mutable "latest" download.
    public static let parakeet = SpeechModel(
        id: "parakeet-tdt-0.6b-v3",
        name: "Parakeet TDT 0.6B v3",
        filename: "ggml-parakeet-tdt-0.6b-v3-f16.bin",
        byteCount: 1_255_897_319,
        sha256: "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f",
        downloadURL: URL(string: "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-f16.bin")!
    )
}

public enum ModelIntegrityError: LocalizedError, Equatable {
    case missing
    case wrongSize(expected: Int64, actual: Int64)
    case wrongDigest
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .missing: return "The model hasn’t been downloaded yet."
        case .wrongSize: return "The model download is incomplete. Please download it again."
        case .wrongDigest: return "The model didn’t pass its integrity check. Please download it again."
        case .unreadable(let detail): return "The model couldn’t be read: \(detail)"
        }
    }
}

public enum ModelIntegrity {
    public static func verify(_ url: URL, model: SpeechModel = .parakeet) -> Result<Void, ModelIntegrityError> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .failure(.missing) }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size == model.byteCount else { return .failure(.wrongSize(expected: model.byteCount, actual: size)) }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let data = try file.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
                digest.update(data: data)
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == model.sha256 ? .success(()) : .failure(.wrongDigest)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }
}
