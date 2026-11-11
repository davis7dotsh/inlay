import Foundation

/// Stored with each archived take so raw ASR and final delivery remain auditable.
public struct TextProcessingRecord: Codable, Equatable, Sendable {
    public static let maximumInputCharacters = 6_000
    public enum Status: String, Codable, Sendable {
        case disabled, unavailable, applied, unchanged, rejected, failed, skipped
    }
    public let dictionaryTerms: [String]
    public let dictionaryChangedText: Bool
    public let inputText: String
    public let outputText: String
    public let enabled: Bool
    public let status: Status
    public let reason: String?
    public let modelID: String?
    public let modelSHA256: String?
    public let engineVersion: String?
    public let processingSeconds: Double?
    public let wallSeconds: Double?
    public let proposedText: String?
    public let verifiedRepairs: [VerifiedTextRepair]?

    public init(dictionaryTerms: [String], dictionaryChangedText: Bool, inputText: String, outputText: String,
                enabled: Bool, status: Status, reason: String? = nil, modelID: String? = nil,
                modelSHA256: String? = nil, engineVersion: String? = nil,
                processingSeconds: Double? = nil, wallSeconds: Double? = nil,
                proposedText: String? = nil, verifiedRepairs: [VerifiedTextRepair]? = nil) {
        self.dictionaryTerms = dictionaryTerms
        self.dictionaryChangedText = dictionaryChangedText
        self.inputText = inputText
        self.outputText = outputText
        self.enabled = enabled
        self.status = status
        self.reason = reason
        self.modelID = modelID
        self.modelSHA256 = modelSHA256
        self.engineVersion = engineVersion
        self.processingSeconds = processingSeconds
        self.wallSeconds = wallSeconds
        self.proposedText = proposedText.map(Self.boundedProposal)
        self.verifiedRepairs = verifiedRepairs.map { Array($0.prefix(8)) }
    }

    private static func boundedProposal(_ text: String) -> String {
        // A single grapheme can contain arbitrarily many combining or joined
        // scalars. Bound code units first so rejected dictionary expansions
        // cannot make archived metadata exceed its read limit on restart.
        var bounded = ""
        var codeUnits = 0
        for scalar in text.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            guard codeUnits + width <= maximumInputCharacters * 8 else { break }
            bounded.unicodeScalars.append(scalar)
            codeUnits += width
        }
        return String(bounded.prefix(maximumInputCharacters * 2))
    }
}
