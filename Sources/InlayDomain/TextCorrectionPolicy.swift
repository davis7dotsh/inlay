import Foundation

/// Conservative, deterministic checks after a generative proofread. These are a
/// safety net, not proof that a rewrite is semantically equivalent.
public enum TextCorrectionPolicy {
    public static let maximumInputCharacters = 6_000

    /// Leave room for text and output in the small context. The complete
    /// dictionary still performs exact replacements even if hints are omitted.
    public static func modelHints(_ terms: [String]) -> [String] {
        var bytes = 0
        return terms.filter { term in
            let count = term.utf8.count
            guard count <= 256, bytes + count <= 4_096 else { return false }
            bytes += count
            return true
        }.prefix(80).map { $0 }
    }

    public static func rejectionReason(original: String, candidate: String, preferredTerms: [String] = []) -> String? {
        evaluate(original: original, candidate: candidate, preferredTerms: preferredTerms).rejectionReason
    }

    public static func evaluate(original: String, candidate: String, preferredTerms: [String] = []) -> TextCorrectionEvaluation {
        var repairs: [VerifiedTextRepair] = []
        let reason = assess(original: original, candidate: candidate, preferredTerms: preferredTerms, repairs: &repairs)
        return TextCorrectionEvaluation(rejectionReason: reason, verifiedRepairs: repairs)
    }

    private static func assess(original: String, candidate: String, preferredTerms: [String], repairs: inout [VerifiedTextRepair]) -> String? {
        guard original.count <= maximumInputCharacters,
              original.utf16.count <= maximumInputCharacters * 4 else { return "The source was too long to validate." }
        let output = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "The text model returned no text." }
        guard output.count <= maximumInputCharacters * 2,
              output.utf16.count <= maximumInputCharacters * 8 else { return "The rewrite was too long." }
        guard !output.contains("<|"), !output.contains("<think>"), !output.contains("</think>") else {
            return "The text model returned control tokens."
        }
        for prefix in ["here is", "here's", "corrected text:", "corrected transcript:", "sure,", "certainly,"] {
            if output.lowercased().hasPrefix(prefix), !original.lowercased().hasPrefix(prefix) {
                return "The text model added commentary."
            }
        }
        guard CorrectionAlignment.isWithinValidationBudget(original: original, candidate: output) else {
            return "The rewrite was too complex to validate."
        }
        // Lists are structured before proofreading; their explicit numbering,
        // bullets, and item count must survive unchanged for continuation.
        guard listMarkers(original) == listMarkers(output) else {
            return "The rewrite changed the list structure."
        }
        // Only Qwen proposes edits. The alignment validates a bounded abandoned
        // phrase beside an explicit repair cue; unrelated source stays protected.
        let repairCheck = CorrectionAlignment.verifyRepairs(original: original, candidate: output)
        repairs = repairCheck.repairs
        let protectedSource = repairCheck.protectedSource
        guard numbers(protectedSource) == numbers(output) else { return "The rewrite changed a number." }
        for term in preferredTerms {
            let pattern = #"(?i)(?<![\p{L}\p{N}\p{M}\p{Pc}\u200C\u200D])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![\p{L}\p{N}\p{M}\p{Pc}\u200C\u200D])"#
            let count = matches(pattern, in: protectedSource).count
            if count > 0, matches(pattern, in: output).count != count {
                return "The rewrite changed a dictionary term."
            }
        }
        let before = words(protectedSource)
        let after = words(output)
        guard numberWords(before) == numberWords(after) else { return "The rewrite changed a quantity." }
        guard !before.isEmpty else { return output == original ? nil : "The rewrite added content." }
        let allowed = Set(preferredTerms.flatMap { words($0) })
        let comparedBefore = CorrectionAlignment.recognizedTerms(in: protectedSource, candidates: allowed.intersection(after)).map(\.word)
        let ratio = Double(after.count) / Double(comparedBefore.count)
        guard ratio >= 0.75, ratio <= 1.35 else { return "The rewrite changed too much text." }
        let shared = orderedOverlap(comparedBefore, after, preferred: allowed)
        guard Double(shared) / Double(max(comparedBefore.count, after.count)) >= 0.72 else {
            return "The rewrite changed too much wording."
        }
        if let reason = CorrectionAlignment.preservationReason(original: protectedSource, candidate: output, preferredTerms: allowed) {
            return reason
        }
        let originalItems = listItems(protectedSource)
        let rewrittenItems = listItems(output)
        for (beforeItem, afterItem) in zip(originalItems, rewrittenItems) {
            let b = words(afterItem)
            let a = CorrectionAlignment.recognizedTerms(in: beforeItem, candidates: allowed.intersection(b)).map(\.word)
            guard Double(orderedOverlap(a, b, preferred: allowed)) / Double(max(1, max(a.count, b.count))) >= 0.72 else {
                return "The rewrite changed a list item."
            }
        }
        return nil
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map { source.substring(with: $0.range) }
    }

    private static func words(_ text: String) -> [String] {
        CorrectionAlignment.tokens(text).map(\.word)
    }

    private static func numbers(_ text: String) -> [String] {
        matches(#"[\p{Sc}+−-]?\s*\p{N}+(?:[.,:/-]\p{N}+)*(?:\s*[%‰])?"#, in: text)
            .map { $0.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression) }
    }

    private static func listMarkers(_ text: String) -> [String] {
        matches(#"(?m)^\s*(?:[0-9]+[.)]|[-*•])(?=\s)"#, in: text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func numberWords(_ words: [String]) -> [String] {
        let protected = Set("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third fourth fifth sixth seventh eighth ninth tenth half quarter percent".split(separator: " ").map(String.init))
        return words.filter { protected.contains($0) }
    }

    private static func listItems(_ text: String) -> [String] {
        matches(#"(?m)^[\t ]*(?:[0-9]+[.)]|[-*•])[\t ]+[^\n]*"#, in: text)
    }

    private static func orderedOverlap(_ before: [String], _ after: [String], preferred: Set<String>) -> Int {
        var row = [Int](repeating: 0, count: after.count + 1)
        for word in before {
            var diagonal = 0
            for (index, candidate) in after.enumerated() {
                let old = row[index + 1]
                let equivalent = word == candidate || (preferred.contains(candidate) &&
                    word.count >= 4 && candidate.count >= 4 && editDistance(word, candidate) <= 2)
                row[index + 1] = equivalent ? diagonal + 1 : max(row[index], old)
                diagonal = old
            }
        }
        return row.last ?? 0
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        guard abs(a.count - b.count) <= 2 else { return 3 }
        let right = Array(b)
        var row = Array(0...right.count)
        for (i, left) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, character) in right.enumerated() {
                let old = row[j + 1]
                row[j + 1] = min(row[j] + 1, old + 1, diagonal + (left == character ? 0 : 1))
                diagonal = old
            }
        }
        return row.last ?? 0
    }
}

/// Stored with each archived take so raw ASR and final delivery remain auditable.
public struct TextProcessingRecord: Codable, Equatable, Sendable {
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
            guard codeUnits + width <= TextCorrectionPolicy.maximumInputCharacters * 8 else { break }
            bounded.unicodeScalars.append(scalar)
            codeUnits += width
        }
        return String(bounded.prefix(TextCorrectionPolicy.maximumInputCharacters * 2))
    }
}
