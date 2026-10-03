import Foundation
import InlayAPI
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct InferenceConfiguration: Sendable {
    public var speechHelper: URL
    public var speechModel: URL
    public var vadModel: URL
    public var proofHelper: URL
    public var proofModel: URL
    public var threads: Int
    public var speechLoadTimeout: Double
    public var speechTimeout: Double
    public var proofLoadTimeout: Double
    public var proofTimeout: Double

    public init(speechHelper: URL, speechModel: URL, vadModel: URL, proofHelper: URL,
                proofModel: URL, threads: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2)),
                speechLoadTimeout: Double = 120, speechTimeout: Double = 180,
                proofLoadTimeout: Double = 30, proofTimeout: Double = 18) {
        self.speechHelper = speechHelper
        self.speechModel = speechModel
        self.vadModel = vadModel
        self.proofHelper = proofHelper
        self.proofModel = proofModel
        self.threads = min(32, max(1, threads))
        self.speechLoadTimeout = Self.deadline(speechLoadTimeout, fallback: 120)
        self.speechTimeout = Self.deadline(speechTimeout, fallback: 180)
        self.proofLoadTimeout = Self.deadline(proofLoadTimeout, fallback: 30)
        self.proofTimeout = Self.deadline(proofTimeout, fallback: 18)
    }

    private static func deadline(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 && value <= 3_600 ? value : fallback
    }
}

public struct InferenceReadiness: Sendable {
    public let available: Bool
    public let message: String
    public let speechLoaded: Bool
    public let proofLoaded: Bool
}

public struct SpeechInferenceResult: Sendable {
    public let text: String
    public let audioSeconds: Double
    public let processingSeconds: Double
    public let language: String
    public let engineVersion: String?
    public let modelSHA256: String?
    public let hints: ModelHintUsage?
}

public struct ProofInferenceResult: Sendable {
    public let text: String
    public let processingSeconds: Double
    public let engineVersion: String?
    public let modelSHA256: String?
}

public enum InferenceError: Error, LocalizedError, Sendable {
    case unavailable(String)
    case invalidRequest(String)
    case invalidResponse(String)
    case timeout(String)
    case cancelled
    case busy

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .invalidRequest(let message),
             .invalidResponse(let message), .timeout(let message): return message
        case .cancelled: return "Inference cancelled."
        case .busy: return "The inference engine is already processing a request."
        }
    }
}

/// Runs whisper.cpp on either host platform, and the native Qwen helper (MLX
/// on macOS, llama.cpp on Linux). Model/runtime paths belong to the server.
public actor NativeInference {
    private let configuration: InferenceConfiguration
    private let speech: HelperProcess
    private let proof: HelperProcess
    private let verifier = InferenceModelVerifier()

    public init(configuration: InferenceConfiguration) {
        self.configuration = configuration
        speech = HelperProcess(
            name: "Whisper", executable: configuration.speechHelper,
            arguments: ["--model", configuration.speechModel.path, "--vad-model", configuration.vadModel.path,
                        "--threads", String(configuration.threads)],
            requiredFiles: [configuration.speechModel, configuration.vadModel],
            loadTimeout: configuration.speechLoadTimeout, lineLimit: 1_048_576
        )
        proof = HelperProcess(
            name: "Qwen", executable: configuration.proofHelper,
            arguments: ["--model", configuration.proofModel.path, "--threads", String(configuration.threads)],
            requiredFiles: [configuration.proofModel], loadTimeout: configuration.proofLoadTimeout,
            lineLimit: 65_536
        )
    }

    public func readiness(proofreadingEnabled: Bool = true) async -> InferenceReadiness {
        let speechState = await speech.snapshot()
        let proofState = await proof.snapshot()
        let helpers = proofreadingEnabled ? [configuration.speechHelper, configuration.proofHelper] : [configuration.speechHelper]
        let models = [configuration.speechModel, configuration.vadModel] + (proofreadingEnabled ? [configuration.proofModel] : [])
        let missing = helpers.first { !FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? models.first { !FileManager.default.isReadableFile(atPath: $0.path) }
        let speechVerified = await verifier.isVerified(configuration.speechModel, pin: speechPin)
        let proofFileVerified = await verifier.isVerified(configuration.proofModel, pin: proofPin)
        let proofVerified = proofFileVerified && (proofManifestSHA256 == nil || proofState.loaded)
        let warm = speechState.loaded && (!proofreadingEnabled || proofState.loaded)
        return InferenceReadiness(
            available: missing == nil && speechVerified && (!proofreadingEnabled || proofVerified),
            message: missing.map { "Missing or inaccessible inference asset: \($0.path)" }
                ?? (!speechVerified || (proofreadingEnabled && !proofVerified) ? "Models need integrity verification." :
                    (warm ? "Models are warm and ready." : "Models need to warm up.")),
            speechLoaded: speechState.loaded, proofLoaded: proofState.loaded
        )
    }

    public func warmUp(proofreadingEnabled: Bool = true) async throws {
        _ = try await verifier.verify(configuration.speechModel, pin: speechPin)
        try await speech.ensureLoaded()
        if proofreadingEnabled {
            _ = try await verifier.verify(configuration.proofModel, pin: proofPin)
            try await proof.ensureLoaded()
        }
    }

    public func transcribe(_ audioURL: URL, language: String, vocabularyTerms: [String],
                           onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> SpeechInferenceResult {
        guard FileManager.default.isReadableFile(atPath: audioURL.path),
              !language.isEmpty, language.utf8.count <= 32, !language.contains("\0"),
              vocabularyTerms.count <= 8_192,
              vocabularyTerms.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= ServerPreferences.maximumVocabularyTermBytes
                      && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      && $0.rangeOfCharacter(from: .controlCharacters) == nil
              }),
              vocabularyTerms.reduce(0, { $0 + $1.utf8.count }) <= 384 * 1024 else {
            throw InferenceError.invalidRequest("Audio, language, or Whisper prompt is invalid.")
        }
        guard Set(vocabularyTerms).count == vocabularyTerms.count else {
            throw InferenceError.invalidRequest("Whisper vocabulary terms must be unique.")
        }
        let digest = try await verifier.verify(configuration.speechModel, pin: speechPin)
        let request = SpeechRequest(id: UUID().uuidString, path: audioURL.path, language: language, vocabularyTerms: vocabularyTerms)
        let data = try JSONEncoder().encode(request)
        guard data.count < 1_048_576 else { throw InferenceError.invalidRequest("The encoded vocabulary exceeds 1 MB.") }
        let response = try await speech.request(data, id: request.id,
                                                timeout: configuration.speechTimeout, onProgress: onProgress)
        guard let text = response.text, text.utf8.count <= 256 * 1024, !text.contains("\0"),
              let duration = response.duration, duration.isFinite, duration >= 0,
              let elapsed = response.elapsed, elapsed.isFinite, elapsed >= 0,
              let language = response.language, !language.isEmpty, language.utf8.count <= 32 else {
            await speech.shutdown()
            throw InferenceError.invalidResponse("Whisper returned an invalid transcript.")
        }
        let hints: ModelHintUsage?
        if let included = response.includedTerms, let omitted = response.omittedTerms,
           let tokenCount = response.tokenCount, let tokenBudget = response.tokenBudget,
           tokenCount >= 0, tokenBudget > 0, tokenCount <= tokenBudget,
           included.count + omitted.count == vocabularyTerms.count,
           Set(included).isDisjoint(with: omitted),
           Set(included + omitted) == Set(vocabularyTerms),
           included == vocabularyTerms.filter(Set(included).contains),
           omitted == vocabularyTerms.filter(Set(omitted).contains) {
            hints = ModelHintUsage(includedTerms: included, omittedTerms: omitted, tokenCount: tokenCount, tokenBudget: tokenBudget)
        } else if response.includedTerms == nil && response.omittedTerms == nil && response.tokenCount == nil && response.tokenBudget == nil {
            hints = nil // Older helper responses have no vocabulary diagnostics.
        } else {
            await speech.shutdown()
            throw InferenceError.invalidResponse("Whisper returned invalid vocabulary diagnostics.")
        }
        let state = await speech.snapshot()
        return SpeechInferenceResult(text: text, audioSeconds: duration, processingSeconds: elapsed,
                                     language: language, engineVersion: state.engineVersion, modelSHA256: digest, hints: hints)
    }

    public func correct(_ text: String, terms: [String], language: String, systemPrompt: String) async throws -> ProofInferenceResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 24 * 1024, !text.contains("\0"),
              terms.count <= 256, terms.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }),
              terms.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
              !language.isEmpty, language.utf8.count <= 32, !language.contains("\0"),
              !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              systemPrompt.utf8.count <= ServerPreferences.maximumProofreadingPromptBytes, !systemPrompt.contains("\0") else {
            throw InferenceError.invalidRequest("The transcript or dictionary exceeds the Qwen correction limit.")
        }
        let request = ProofRequest(id: UUID().uuidString, text: text, terms: terms, language: language, systemPrompt: systemPrompt)
        let data = try JSONEncoder().encode(request)
        guard data.count <= 64 * 1024 else {
            throw InferenceError.invalidRequest("The encoded correction request exceeds 64 KB.")
        }
        let digest = try await verifier.verify(configuration.proofModel, pin: proofPin)
        let response = try await proof.request(data, id: request.id, timeout: configuration.proofTimeout)
        guard let corrected = response.text, !corrected.isEmpty, corrected.utf8.count <= 24 * 1024,
              !corrected.contains("\0"), let elapsed = response.elapsed, elapsed.isFinite, elapsed >= 0 else {
            await proof.shutdown()
            throw InferenceError.invalidResponse("Qwen returned an invalid correction.")
        }
        let state = await proof.snapshot()
        return ProofInferenceResult(text: corrected, processingSeconds: elapsed, engineVersion: state.engineVersion,
                                    modelSHA256: digest ?? proofManifestSHA256)
    }

    public func cancel() async {
        await verifier.cancel()
        await speech.cancel()
        await proof.cancel()
    }

    public func shutdown() async {
        await verifier.cancel()
        await speech.shutdown()
        await proof.shutdown()
    }

    private var speechPin: InferenceModelPin? {
        // Sources/InlayCore/SpeechModel.swift: SpeechModel.turbo.
        InferenceModelPin(bytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69")
    }

    private var proofPin: InferenceModelPin? {
        #if os(macOS)
        // The MLX helper verifies all six files against TextModel.qwen before
        // emitting ready. Avoid hashing its 2 GB weights twice on startup.
        return nil
        #else
        // Pinned Unsloth Qwen3-4B-Instruct-2507 Q4_K_M, Server/README.md.
        return InferenceModelPin(bytes: 2_497_281_120,
            sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597")
        #endif
    }

    private var proofManifestSHA256: String? {
        #if os(macOS)
        return "6689706a7d1a746920df5c5d5dc1e8ed3280790a542085d6e3c870c565e77307"
        #else
        return nil
        #endif
    }
}

private struct InferenceModelPin: Hashable, Sendable {
    let bytes: Int64?
    let sha256: String
}

/// Hashes regular model files off the server actor. Cache entries bind a digest
/// to inode, size, modification and change times, and are invalidated on edits.
private actor InferenceModelVerifier {
    private struct Fingerprint: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64

        init(_ info: stat) {
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            #if canImport(Darwin)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanos = Int64(info.st_ctimespec.tv_nsec)
            #else
            modifiedSeconds = Int64(info.st_mtim.tv_sec)
            modifiedNanos = Int64(info.st_mtim.tv_nsec)
            changedSeconds = Int64(info.st_ctim.tv_sec)
            changedNanos = Int64(info.st_ctim.tv_nsec)
            #endif
        }
    }

    private struct Verified: Sendable {
        let pin: InferenceModelPin
        let fingerprint: Fingerprint
    }

    private struct Pending {
        let id: UUID
        let task: Task<Verified, Error>
    }

    private var verified: [URL: Verified] = [:]
    private var pending: [URL: Pending] = [:]

    func isVerified(_ url: URL, pin: InferenceModelPin?) -> Bool {
        guard let pin else { return true }
        guard let entry = verified[url], entry.pin == pin,
              let current = try? Self.fingerprint(url), current == entry.fingerprint else { return false }
        return true
    }

    func verify(_ url: URL, pin: InferenceModelPin?) async throws -> String? {
        try Task.checkCancellation()
        guard let pin else { return nil }
        if isVerified(url, pin: pin) { return pin.sha256 }
        verified[url] = nil
        let operation: Pending
        if let existing = pending[url] {
            operation = existing
        } else {
            operation = Pending(id: UUID(), task: Task.detached(priority: .utility) {
                try Self.hash(url, pin: pin)
            })
            pending[url] = operation
        }
        defer { if pending[url]?.id == operation.id { pending[url] = nil } }
        let result = try await withTaskCancellationHandler {
            try await operation.task.value
        } onCancel: { operation.task.cancel() }
        try Task.checkCancellation()
        guard result.pin == pin else {
            throw InferenceError.unavailable("Model verification configuration changed.")
        }
        verified[url] = result
        return pin.sha256
    }

    func cancel() {
        for operation in pending.values { operation.task.cancel() }
        pending.removeAll()
    }

    private nonisolated static func fingerprint(_ url: URL) throws -> Fingerprint {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw InferenceError.unavailable("The inference model must be a readable regular file: \(url.lastPathComponent)")
        }
        return Fingerprint(info)
    }

    private nonisolated static func hash(_ url: URL, pin: InferenceModelPin) throws -> Verified {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InferenceError.unavailable("Could not read inference model: \(url.lastPathComponent)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw InferenceError.unavailable("The inference model must be a regular file.")
        }
        let before = Fingerprint(info)
        if let expected = pin.bytes, before.size != expected {
            throw InferenceError.unavailable("The \(url.lastPathComponent) model has an incorrect size; install the pinned model.")
        }
        var digest = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            total += Int64(chunk.count)
            guard total <= before.size else {
                throw InferenceError.unavailable("The model changed during integrity verification.")
            }
            digest.update(data: chunk)
        }
        guard total == before.size, fstat(descriptor, &info) == 0,
              Fingerprint(info) == before, try fingerprint(url) == before else {
            throw InferenceError.unavailable("The model changed during integrity verification.")
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == pin.sha256 else {
            throw InferenceError.unavailable("The \(url.lastPathComponent) model failed SHA-256 verification; install the pinned model.")
        }
        return Verified(pin: pin, fingerprint: before)
    }
}

private struct SpeechRequest: Encodable {
    let type = "transcribe"
    let id: String
    let path: String
    let language: String
    let vocabularyTerms: [String]
}

private struct ProofRequest: Encodable {
    let type = "correct"
    let id: String
    let text: String
    let terms: [String]
    let language: String
    let systemPrompt: String
}
