import Foundation
@_exported import InlayDomain

public enum InlayAPI {
    public static let version = GeneratedShared.apiVersion
    public static let defaultPort = GeneratedShared.defaultPort
    public static let maximumRecordingSeconds = GeneratedShared.maximumRecordingSeconds
    public static let maximumChunkBytes = GeneratedShared.maximumChunkBytes
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}






public struct StorageUsage: Codable, Equatable, Sendable {
    public var generationCount: Int
    public var audioByteCount: Int64
    public var inferenceByteCount: Int64
    public var originalByteCount: Int64
    public var oldestAudioAt: Date?
    public var freeByteCount: Int64
    public var audioRetentionDays: Int
    public init(generationCount: Int, audioByteCount: Int64, inferenceByteCount: Int64,
                originalByteCount: Int64, oldestAudioAt: Date? = nil, freeByteCount: Int64,
                audioRetentionDays: Int) {
        self.generationCount = generationCount; self.audioByteCount = audioByteCount
        self.inferenceByteCount = inferenceByteCount; self.originalByteCount = originalByteCount
        self.oldestAudioAt = oldestAudioAt; self.freeByteCount = freeByteCount
        self.audioRetentionDays = audioRetentionDays
    }
}

public struct PurgeAudioRequest: Codable, Equatable, Sendable {
    public var olderThanDays: Int?
    public var kind: AudioKind?
    public init(olderThanDays: Int? = nil, kind: AudioKind? = nil) {
        self.olderThanDays = olderThanDays; self.kind = kind
    }
}

public struct PurgeAudioResult: Codable, Equatable, Sendable {
    public var purgedRecordCount: Int
    public var freedByteCount: Int64
    public init(purgedRecordCount: Int, freedByteCount: Int64) {
        self.purgedRecordCount = purgedRecordCount; self.freedByteCount = freedByteCount
    }
}

public struct ServerPreferences: Codable, Equatable, Sendable {
    public var language: String
    public var proofreadingPrompt: String
    public var vocabulary: String
    public var dictionary: PersonalDictionary
    public var textCorrectionEnabled: Bool
    public var keepOriginalAudio: Bool
    public var audioRetentionDays: Int
    public static let maximumProofreadingPromptBytes = 4096
    public static let maximumVocabularyTermBytes = 16_384
    public static var defaultProofreadingPrompt: String { GeneratedShared.defaultProofreadingPrompt }
    // Clients decode these as a closed enum; keep the wire values stable.
    public static var supportedLanguages: [String] { GeneratedShared.supportedLanguages }
    public init(language: String = "en", proofreadingPrompt: String = Self.defaultProofreadingPrompt, vocabulary: String = "",
                dictionary: PersonalDictionary = .default, textCorrectionEnabled: Bool = true,
                keepOriginalAudio: Bool = true, audioRetentionDays: Int = 90) {
        self.language = language; self.proofreadingPrompt = proofreadingPrompt; self.vocabulary = vocabulary
        self.dictionary = dictionary; self.textCorrectionEnabled = textCorrectionEnabled
        self.keepOriginalAudio = keepOriginalAudio; self.audioRetentionDays = audioRetentionDays
    }
    private enum CodingKeys: String, CodingKey {
        case language, proofreadingPrompt, vocabulary, dictionary, textCorrectionEnabled, keepOriginalAudio, audioRetentionDays
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        language = try values.decode(String.self, forKey: .language)
        proofreadingPrompt = try values.decodeIfPresent(String.self, forKey: .proofreadingPrompt) ?? Self.defaultProofreadingPrompt
        vocabulary = try values.decode(String.self, forKey: .vocabulary)
        dictionary = try values.decode(PersonalDictionary.self, forKey: .dictionary)
        textCorrectionEnabled = try values.decode(Bool.self, forKey: .textCorrectionEnabled)
        keepOriginalAudio = try values.decode(Bool.self, forKey: .keepOriginalAudio)
        audioRetentionDays = try values.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? 90
    }
    public var validationError: String? {
        if !Self.supportedLanguages.contains(language) { return "Choose a supported language." }
        if proofreadingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The cleanup system prompt cannot be empty."
        }
        if proofreadingPrompt.utf8.count > Self.maximumProofreadingPromptBytes || proofreadingPrompt.contains("\0") {
            return "The cleanup system prompt must fit within 4 KB and contain no null characters."
        }
        if vocabulary.utf8.count > 16_384 || vocabulary.unicodeScalars.contains(where: {
            !$0.properties.isWhitespace && [.control, .format].contains($0.properties.generalCategory)
        }) {
            return "Vocabulary must fit within 16 KB and contain no hidden control characters."
        }
        if dictionary.lists.contains(where: { list in
            list.entries.contains { $0.term.utf8.count > Self.maximumVocabularyTermBytes }
        }) {
            return "Each dictionary word must fit within 16 KB for speech recognition."
        }
        return dictionary.validationError
    }
}

public struct PreferencesSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var preferences: ServerPreferences
    public init(revision: Int = 0, preferences: ServerPreferences = .init()) {
        self.revision = revision; self.preferences = preferences
    }
}

public struct ModelRuntimeInfo: Codable, Equatable, Sendable {
    public var modelID: String
    public var backend: String
    public var ready: Bool
    public var message: String?
    public init(modelID: String, backend: String, ready: Bool, message: String? = nil) {
        self.modelID = modelID; self.backend = backend; self.ready = ready; self.message = message
    }
}

public struct ServerHealth: Codable, Equatable, Sendable {
    public var apiVersion: Int
    public var serverVersion: String
    public var isDev: Bool
    public var ready: Bool
    public var speech: ModelRuntimeInfo
    public var proofreading: ModelRuntimeInfo
    public var message: String?
    public init(apiVersion: Int = InlayAPI.version, serverVersion: String = "0.0.0-dev", isDev: Bool = true,
                ready: Bool, speech: ModelRuntimeInfo, proofreading: ModelRuntimeInfo, message: String? = nil) {
        self.apiVersion = apiVersion; self.serverVersion = serverVersion; self.isDev = isDev
        self.ready = ready; self.speech = speech; self.proofreading = proofreading; self.message = message
    }
}

public enum GenerationMode: String, Codable, Sendable { case dictation, test, file }
public enum GenerationStatus: String, Codable, Sendable {
    case receiving, queued, transcribing, proofreading, completed, failed, cancelled
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}
public enum AudioKind: String, Codable, Sendable { case inference, original }

public struct CreateGenerationRequest: Codable, Sendable {
    public var requestID: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public init(requestID: UUID = UUID(), device: DeviceIdentity, mode: GenerationMode = .dictation) {
        self.requestID = requestID; self.device = device; self.mode = mode
    }
}

public struct AudioStreamFormat: Codable, Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public init(sampleRate: Int, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
}

public struct AudioChunkReceipt: Codable, Sendable {
    public var nextSequence: Int
    public var frameCount: Int64
    public init(nextSequence: Int, frameCount: Int64) { self.nextSequence = nextSequence; self.frameCount = frameCount }
}

public struct FinishGenerationRequest: Codable, Sendable {
    public var inferenceFrames: Int64
    public var originalFrames: Int64?
    public var continuationID: UUID?
    /// Ranked terms read from the destination window; they follow dictionary names as
    /// Qwen proofreading hints. The window image and its recognized text stay on the Mac.
    public var screenContextTerms: [String]?
    public init(inferenceFrames: Int64, originalFrames: Int64? = nil, continuationID: UUID? = nil,
                screenContextTerms: [String]? = nil) {
        self.inferenceFrames = inferenceFrames; self.originalFrames = originalFrames; self.continuationID = continuationID
        self.screenContextTerms = screenContextTerms
    }
}

public struct AudioArtifact: Codable, Equatable, Sendable {
    public var filename: String
    public var sampleRate: Int
    public var channels: Int
    public var frameCount: Int64
    public var byteCount: Int64
    public var encoding: String
    public var duration: Double { Double(frameCount) / Double(max(1, sampleRate)) }
    public init(filename: String, sampleRate: Int, channels: Int, frameCount: Int64, byteCount: Int64, encoding: String = "pcm_f32le") {
        self.filename = filename; self.sampleRate = sampleRate; self.channels = channels
        self.frameCount = frameCount; self.byteCount = byteCount; self.encoding = encoding
    }
}


public struct DeliveryReceipt: Codable, Equatable, Sendable {
    public var status: String
    public var message: String?
    public var reportedAt: Date
    public init(status: String, message: String? = nil, reportedAt: Date = Date()) {
        self.status = status; self.message = message; self.reportedAt = reportedAt
    }
}


public enum WisprFlowArtifactName: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceJSON = "source.json"
    case sourceWAV = "source.wav"
    case opusJSON = "opus.json"
    case screenshotPNG = "screenshot.png"
    /// Typed omission only: Wispr Flow's builtInAudio format is not known.
    case builtInAudio = "built-in-audio.bin"
}

public enum WisprFlowImportLimits {
    public static let maximumArtifactBytes = 8_388_608
    public static let maximumDictionaryBytes = 8_388_608
}

public struct WisprFlowArtifactManifest: Codable, Equatable, Sendable {
    public var filename: WisprFlowArtifactName
    public var byteCount: Int
    public var sha256: String
    public init(filename: WisprFlowArtifactName, byteCount: Int, sha256: String) {
        self.filename = filename; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct WisprFlowImportRequest: Codable, Equatable, Sendable {
    public var sourceID: UUID
    public var createdAt: Date
    public var sourceStatus: String?
    public var finalText: String
    public var rawText: String
    public var durationSeconds: Double?
    public var variantNames: [String]
    public var artifacts: [WisprFlowArtifactManifest]
    /// Source-reported media versions whose bytes cannot be uploaded. The
    /// source.json archive records the originating row and reason for each one.
    public var unarchivedArtifacts: [WisprFlowArtifactManifest]?
    public init(sourceID: UUID, createdAt: Date, sourceStatus: String? = nil, finalText: String,
                rawText: String, durationSeconds: Double? = nil, variantNames: [String] = [],
                artifacts: [WisprFlowArtifactManifest], unarchivedArtifacts: [WisprFlowArtifactManifest]? = nil) {
        self.sourceID = sourceID; self.createdAt = createdAt; self.sourceStatus = sourceStatus
        self.finalText = finalText; self.rawText = rawText; self.durationSeconds = durationSeconds
        self.variantNames = variantNames; self.artifacts = artifacts
        self.unarchivedArtifacts = unarchivedArtifacts
    }
}

public struct WisprFlowImportSession: Codable, Sendable {
    public var id: UUID
    public init(id: UUID) { self.id = id }
}

public struct WisprFlowArtifactReceipt: Codable, Sendable {
    public var filename: WisprFlowArtifactName
    public var byteCount: Int
    public init(filename: WisprFlowArtifactName, byteCount: Int) {
        self.filename = filename; self.byteCount = byteCount
    }
}

public enum WisprFlowImportOutcome: String, Codable, Sendable { case imported, enriched, skipped, partial }

public struct WisprFlowImportResult: Codable, Sendable {
    public var outcome: WisprFlowImportOutcome
    public var record: GenerationRecord
    public var unarchivedArtifactNames: [WisprFlowArtifactName]
    public init(outcome: WisprFlowImportOutcome, record: GenerationRecord,
                unarchivedArtifactNames: [WisprFlowArtifactName] = []) {
        self.outcome = outcome; self.record = record
        self.unarchivedArtifactNames = unarchivedArtifactNames
    }
}

public struct WisprFlowKnownIDsRequest: Codable, Sendable {
    public var sourceIDs: [UUID]
    public init(sourceIDs: [UUID]) { self.sourceIDs = sourceIDs }
}

public struct WisprFlowKnownIDsResponse: Codable, Sendable {
    public var knownSourceIDs: [UUID]
    public init(knownSourceIDs: [UUID]) { self.knownSourceIDs = knownSourceIDs }
}

public struct WisprFlowDictionaryArchiveReceipt: Codable, Sendable {
    public var byteCount: Int
    public var sha256: String
    public init(byteCount: Int, sha256: String) { self.byteCount = byteCount; self.sha256 = sha256 }
}

public struct ImportedSource: Codable, Equatable, Sendable {
    public var provider: String
    public var sourceID: UUID
    public var sourceStatus: String?
    public var importedAt: Date
    public var variantNames: [String]
    public var artifactNames: [WisprFlowArtifactName]
    public var durationSeconds: Double?
    /// Digest of the most recently submitted source.json. It can differ from the
    /// archived file digest after earlier source versions are merged in.
    public var sourceSHA256: String
    /// Digests of the actual archived artifacts, including merged source.json.
    public var artifactSHA256: [String: String]
    /// Source-reported media digests whose bytes are not in the archive. Full
    /// version, size, and reason details live in source.json.
    public var unarchivedArtifactSHA256: [String: String]?
    public init(sourceID: UUID, sourceStatus: String?, importedAt: Date, variantNames: [String],
                artifactNames: [WisprFlowArtifactName], durationSeconds: Double?, sourceSHA256: String,
                artifactSHA256: [String: String]) {
        provider = "wispr-flow"; self.sourceID = sourceID; self.sourceStatus = sourceStatus
        self.importedAt = importedAt; self.variantNames = variantNames; self.artifactNames = artifactNames
        self.durationSeconds = durationSeconds; self.sourceSHA256 = sourceSHA256; self.artifactSHA256 = artifactSHA256
        unarchivedArtifactSHA256 = [:]
    }
}

public struct GenerationRecord: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: Int
    public var id: UUID
    public var requestID: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public var status: GenerationStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var settings: PreferencesSnapshot
    public var inferenceAudio: AudioArtifact?
    public var originalAudio: AudioArtifact?
    public var originalAudioOmittedReason: String?
    public var rawText: String
    public var finalText: String
    public var insertionText: String
    public var previewText: String
    public var detectedLanguage: String?
    public var speech: ModelProvenance?
    public var proofreading: ModelProvenance?
    public var textProcessing: TextProcessingRecord?
    public var screenContextTerms: [String]?
    public var recognitionHints: ModelHintUsage?
    public var proofreadingHints: ModelHintUsage?
    public var formattingRejectionReason: String?
    public var consumedListControls: [ListControlSpan]?
    public var continuation: DictationContinuation?
    public var delivery: DeliveryReceipt?
    public var error: String?
    public var progress: Double?
    public var queuePosition: Int?
    public var importedSource: ImportedSource?
    public var audioSeconds: Double { inferenceAudio?.duration ?? importedSource?.durationSeconds ?? 0 }
    public init(id: UUID = UUID(), requestID: UUID, device: DeviceIdentity, mode: GenerationMode = .dictation,
                status: GenerationStatus = .receiving, createdAt: Date = Date(), settings: PreferencesSnapshot) {
        schemaVersion = 1; self.id = id; self.requestID = requestID; self.device = device; self.mode = mode
        self.status = status; self.createdAt = createdAt; updatedAt = createdAt; self.settings = settings
        rawText = ""; finalText = ""; insertionText = ""; previewText = ""
    }
}

/// History list projection (API 4): full records load via GET /v1/generations/:id.
public struct GenerationSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var device: DeviceIdentity
    public var mode: GenerationMode
    public var status: GenerationStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var previewText: String
    public var queuePosition: Int?
    public var originalAudioOmittedReason: String?
    public var importedSource: ImportedSource?
    public init(id: UUID, device: DeviceIdentity, mode: GenerationMode, status: GenerationStatus,
                createdAt: Date, updatedAt: Date, previewText: String, queuePosition: Int? = nil,
                originalAudioOmittedReason: String? = nil, importedSource: ImportedSource? = nil) {
        self.id = id; self.device = device; self.mode = mode; self.status = status
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.previewText = previewText
        self.queuePosition = queuePosition
        self.originalAudioOmittedReason = originalAudioOmittedReason
        self.importedSource = importedSource
    }
}

public struct GenerationPage: Codable, Sendable {
    public var items: [GenerationSummary]
    public var nextCursor: String?
    public init(items: [GenerationSummary], nextCursor: String? = nil) { self.items = items; self.nextCursor = nextCursor }
}

