import Foundation

public struct TextCorrectionEvaluation: Equatable, Sendable {
    public let rejectionReason: String?
    public let verifiedRepairs: [VerifiedTextRepair]
}

/// Offsets refer to the original pre-proofreading text, using Foundation's UTF-16 indexing.
public struct TextRepairSpan: Codable, Equatable, Sendable {
    public let locationUTF16: Int
    public let lengthUTF16: Int
    public let text: String

    init(_ range: NSRange, in source: NSString) {
        locationUTF16 = range.location
        lengthUTF16 = range.length
        text = String(source.substring(with: range).prefix(512))
    }
}

public struct VerifiedTextRepair: Codable, Equatable, Sendable {
    public let abandoned: TextRepairSpan
    public let cue: TextRepairSpan
    public let replacement: TextRepairSpan
}

enum CorrectionAlignment {
    struct Token {
        var word: String
        var range: NSRange
    }

    private static let repairCuePattern = #"(?i)\b(?:er|err|erm|i\s+mean|correction|sorry)\b"#
    private static let repairSpanLimit = 8
    private static let hesitations: Set<String> = ["um", "uh", "er", "err", "erm"]
    private static let negatives: Set<String> = [
        "no", "not", "never", "neither", "nor", "without", "nothing", "nobody", "none", "nowhere",
    ]
    private static let contractions: [String: [String]] = [
        "cannot": ["can", "not"], "can't": ["can", "not"], "won't": ["will", "not"],
        "shan't": ["shall", "not"], "don't": ["do", "not"], "doesn't": ["does", "not"],
        "didn't": ["did", "not"], "haven't": ["have", "not"], "hasn't": ["has", "not"],
        "hadn't": ["had", "not"], "isn't": ["is", "not"], "aren't": ["are", "not"],
        "wasn't": ["was", "not"], "weren't": ["were", "not"], "couldn't": ["could", "not"],
        "wouldn't": ["would", "not"], "shouldn't": ["should", "not"], "mustn't": ["must", "not"],
        "needn't": ["need", "not"], "mightn't": ["might", "not"],
    ]

    static func tokens(_ text: String) -> [Token] {
        let source = text as NSString
        return matches(#"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#, text).flatMap { match in
            let word = source.substring(with: match.range).lowercased().replacingOccurrences(of: "’", with: "'")
            return (contractions[word] ?? [word]).map { Token(word: $0, range: match.range) }
        }
    }

    static func isWithinValidationBudget(original: String, candidate: String) -> Bool {
        // Two score passes run sequentially. Cap each UInt32 matrix at 64 MB;
        // grapheme counts alone do not bound the number of Unicode word tokens.
        let maximumCells = 16_000_000
        let input = tokens(original)
        let width = tokens(candidate).count + 1
        guard input.count + 1 <= maximumCells / width else { return false }

        // Failed or ambiguous cues do not count toward the eight verified
        // repairs. Budget every possible span's full-output scan, including its
        // two anchors on each side, before starting any repair search.
        let maximumScanComparisons = 16_000_000
        let cueCount = matches(repairCuePattern, original).count
        let hesitationCount = input.filter { hesitations.contains($0.word) }.count
        let comparisonsPerOutputToken = cueCount * repairSpanLimit * repairSpanLimit * (repairSpanLimit + 4)
            + hesitationCount * 4
        return comparisonsPerOutputToken <= maximumScanComparisons / width
    }

    static func preservationReason(original: String, candidate: String, preferredTerms: Set<String>) -> String? {
        let output = tokens(candidate)
        let input = recognizedTerms(in: original, candidates: preferredTerms.intersection(output.map(\.word)))
        let inputNegatives = input.indices.filter { isNegative(input[$0].word) }
        let outputNegatives = output.indices.filter { isNegative(output[$0].word) }
        guard inputNegatives.map({ input[$0].word }) == outputNegatives.map({ output[$0].word }) else {
            return "The rewrite changed a negation."
        }

        let aligned = alignment(input, output, preferredTerms: preferredTerms)
        // Vocabulary hints can correct a matching spoken name, but cannot
        // license inserting that name in place of unrelated dictated content.
        let matchedOutput = Set(aligned.map(\.1))
        for index in output.indices where preferredTerms.contains(output[index].word) && !matchedOutput.contains(index) {
            return "The rewrite introduced an unsupported dictionary term."
        }
        // Use nonnegative anchors: matching the word "not" itself would hide a
        // move from one otherwise unchanged action to another.
        let positiveInput = input.indices.filter { !isNegative(input[$0].word) }
        let positiveOutput = output.indices.filter { !isNegative(output[$0].word) }
        let positiveAlignment = alignment(positiveInput.map { input[$0] }, positiveOutput.map { output[$0] }, preferredTerms: preferredTerms)
            .map { (positiveInput[$0.0], positiveOutput[$0.1]) }
        for (sourceNegative, outputNegative) in zip(inputNegatives, outputNegatives) {
            let left = positiveAlignment.last { $0.0 < sourceNegative }?.1 ?? -1
            let right = positiveAlignment.first { $0.0 > sourceNegative }?.1 ?? output.count
            guard left < outputNegative, outputNegative < right else {
                return "The rewrite moved a negation to different wording."
            }
        }

        let retained = Set(aligned.map(\.0))
        for unit in answerUnits(original, input) where !unit.isEmpty {
            let retainedCount = unit.filter { retained.contains($0) }.count
            // Short answers need every token. A surviving article elsewhere must
            // not stand in for an omitted "I agree", and each occurrence aligns once.
            let minimum = unit.count <= 4 ? unit.count : max(1, Int(ceil(Double(unit.count) * 0.5)))
            guard retainedCount >= minimum else {
                return "The rewrite removed an answer or sentence."
            }
        }
        return nil
    }

    static func verifyRepairs(original: String, candidate: String) -> (protectedSource: String, repairs: [VerifiedTextRepair]) {
        let source = original as NSString
        let input = tokens(original)
        let output = tokens(candidate).map(\.word)
        let units = answerUnits(original, input)
        var removals: [NSRange] = []
        var repairs: [VerifiedTextRepair] = []
        var repairedUnits: Set<Int> = []
        let cues = matches(repairCuePattern, original)
        for cue in cues where repairs.count < 8 {
            guard !touchesHyphen(cue.range, in: source),
                  let firstCue = input.firstIndex(where: { NSIntersectionRange($0.range, cue.range).length > 0 }),
                  let lastCue = input.lastIndex(where: { NSIntersectionRange($0.range, cue.range).length > 0 }),
                  firstCue > 0, lastCue + 1 < input.count,
                  let unitIndex = units.firstIndex(where: { $0.contains(firstCue) }),
                  !repairedUnits.contains(unitIndex),
                  let unitStart = units[unitIndex].first, let unitEnd = units[unitIndex].last,
                  firstCue > unitStart, lastCue < unitEnd else { continue }
            let beforeGap = source.substring(with: NSRange(location: NSMaxRange(input[firstCue - 1].range), length: cue.range.location - NSMaxRange(input[firstCue - 1].range)))
            let afterGap = source.substring(with: NSRange(location: NSMaxRange(cue.range), length: input[lastCue + 1].range.location - NSMaxRange(cue.range)))
            // Punctuation establishes a correction position. Quoted tokens and
            // identifiers named err, ordinary "or", and apologies are not cues.
            let separators = CharacterSet(charactersIn: ",—–-")
            let quotes = CharacterSet(charactersIn: "\"'‘’“”`")
            guard beforeGap.rangeOfCharacter(from: separators) != nil,
                  beforeGap.rangeOfCharacter(from: quotes) == nil,
                  afterGap.rangeOfCharacter(from: quotes) == nil else { continue }
            let cueWords = Array(input[firstCue...lastCue].map(\.word))
            if cueWords != ["i", "mean"] && afterGap.rangeOfCharacter(from: separators) == nil { continue }

            var verified: (Int, Int)?
            // At most eight source tokens immediately before the cue may be
            // abandoned, within one answer. Choose the smallest anchored deletion.
            for start in stride(from: firstCue - 1, through: max(unitStart, firstCue - repairSpanLimit), by: -1) {
                if start > 0, input[start].range == input[start - 1].range { continue }
                for end in (lastCue + 1)...min(unitEnd, lastCue + repairSpanLimit) {
                    if end + 1 < input.count, input[end].range == input[end + 1].range { continue }
                    let left = Array(input[max(unitStart, start - 2)..<start].map(\.word))
                    let replacement = Array(input[(lastCue + 1)...end].map(\.word))
                    let right = Array(input[(end + 1)..<min(unitEnd + 1, end + 3)].map(\.word))
                    // Hesitations and "sorry" can also introduce new thoughts. Only exempt
                    // a single-word replacement, direct quantity change, or a
                    // repeated statement with changed polarity. Whole unrelated
                    // clauses stay protected.
                    if cueWords != ["i", "mean"] && cueWords != ["correction"], !isLocalizedRepair(
                        abandoned: Array(input[start..<firstCue].map(\.word)), replacement: replacement,
                        anchoredWordReplacement: start > unitStart || end == unitEnd
                    ) { continue }
                    let expected = left + replacement + right
                    let positions = occurrenceStarts(expected, in: output).filter { position in
                        (start != 0 || position == 0) && (end + 1 != input.count || position + expected.count == output.count)
                    }
                    guard positions.count == 1 else { continue }
                    verified = (start, end)
                    break
                }
                if verified != nil { break }
            }
            guard let (start, end) = verified else { continue }
            let abandonedRange = NSRange(location: input[start].range.location, length: NSMaxRange(input[firstCue - 1].range) - input[start].range.location)
            let replacementRange = NSRange(location: input[lastCue + 1].range.location, length: NSMaxRange(input[end].range) - input[lastCue + 1].range.location)
            let removal = NSRange(location: abandonedRange.location, length: input[lastCue + 1].range.location - abandonedRange.location)
            guard !removals.contains(where: { NSIntersectionRange($0, removal).length > 0 }) else { continue }
            removals.append(removal)
            repairs.append(VerifiedTextRepair(abandoned: TextRepairSpan(abandonedRange, in: source), cue: TextRepairSpan(cue.range, in: source), replacement: TextRepairSpan(replacementRange, in: source)))
            repairedUnits.insert(unitIndex)
        }
        let protectedSource = NSMutableString(string: original)
        for removal in removals.sorted(by: { $0.location > $1.location }) {
            protectedSource.replaceCharacters(in: removal, with: "")
        }
        return (omittingVerifiedHesitations(protectedSource as String, candidate: candidate), repairs)
    }

    private static func isLocalizedRepair(abandoned: [String], replacement: [String], anchoredWordReplacement: Bool) -> Bool {
        guard abandoned != replacement else { return false }
        // A whole short answer before an apology must not be mistaken for the
        // first word of a following clause ("Agreed, sorry, I was distracted").
        if anchoredWordReplacement, abandoned.count == 1, replacement.count == 1 { return true }
        let quantities = Set("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand million billion trillion first second third fourth fifth sixth seventh eighth ninth tenth half quarter percent".split(separator: " ").map(String.init))
        func isQuantity(_ word: String) -> Bool {
            quantities.contains(word) || word.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
        }
        if abandoned.allSatisfy(isQuantity), replacement.allSatisfy(isQuantity) { return true }
        let repeated = abandoned.filter { !isNegative($0) }
        return !repeated.isEmpty && repeated == replacement.filter { !isNegative($0) }
            && abandoned.filter(isNegative) != replacement.filter(isNegative)
    }

    // A proposal may remove an isolated hesitation without abandoning any
    // wording. Adjacent anchors must survive, and quoted words / identifiers do
    // not qualify. This validates the model's edit; it never cleans the source.
    private static func omittingVerifiedHesitations(_ original: String, candidate: String) -> String {
        let source = original as NSString
        let input = tokens(original)
        let output = tokens(candidate).map(\.word)
        let punctuation = CharacterSet(charactersIn: ",—–-")
        let quotes = CharacterSet(charactersIn: "\"'‘’“”`")
        var removals: [NSRange] = []
        for index in input.indices where hesitations.contains(input[index].word) {
            guard !touchesHyphen(input[index].range, in: source) else { continue }
            let start = index == 0 ? 0 : NSMaxRange(input[index - 1].range)
            let end = index + 1 == input.count ? source.length : input[index + 1].range.location
            let before = source.substring(with: NSRange(location: start, length: input[index].range.location - start))
            let after = source.substring(with: NSRange(location: NSMaxRange(input[index].range), length: end - NSMaxRange(input[index].range)))
            guard before.rangeOfCharacter(from: quotes) == nil, after.rangeOfCharacter(from: quotes) == nil,
                  (index == 0 || before.rangeOfCharacter(from: punctuation) != nil),
                  (index == 0 || index + 1 == input.count || after.rangeOfCharacter(from: punctuation) != nil) else { continue }
            let left = Array(input[max(0, index - 2)..<index].map(\.word))
            let right = Array(input[(index + 1)..<min(input.count, index + 3)].map(\.word))
            let expected = left + right
            let occurrences = occurrenceStarts(expected, in: output).filter { position in
                (index != 0 || position == 0) && (index + 1 != input.count || position + expected.count == output.count)
            }
            if occurrences.count == 1 { removals.append(input[index].range) }
        }
        let result = NSMutableString(string: original)
        for range in removals.reversed() { result.replaceCharacters(in: range, with: "") }
        return result as String
    }

    private static func touchesHyphen(_ range: NSRange, in source: NSString) -> Bool {
        // ASCII hyphens attached to a word belong to identifiers or compounds;
        // spaced hyphens can still delimit a spoken correction or hesitation.
        (range.location > 0 && source.character(at: range.location - 1) == 45)
            || (NSMaxRange(range) < source.length && source.character(at: NSMaxRange(range)) == 45)
    }

    private static func answerUnits(_ text: String, _ tokens: [Token]) -> [[Int]] {
        guard !tokens.isEmpty else { return [] }
        let source = text as NSString
        let markers = matches(#"(?m)^[\t ]*(?:[0-9]+[.)]|[-*•])[\t ]+"#, text).map(\.range)
        var result: [[Int]] = []
        var current: [Int] = []
        for index in tokens.indices {
            let token = tokens[index]
            if markers.contains(where: { NSIntersectionRange($0, token.range).length > 0 }) { continue }
            if let previous = current.last, token.range.location >= NSMaxRange(tokens[previous].range) {
                let gap = source.substring(with: NSRange(location: NSMaxRange(tokens[previous].range), length: token.range.location - NSMaxRange(tokens[previous].range)))
                if gap.contains("\n") || gap.range(of: #"[.!?](?:\s|[\"'’”])"#, options: .regularExpression) != nil {
                    result.append(current)
                    current = []
                }
            }
            current.append(index)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func occurrenceStarts(_ phrase: [String], in words: [String]) -> [Int] {
        guard !phrase.isEmpty, phrase.count <= words.count else { return [] }
        return (0...(words.count - phrase.count)).filter { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }

    private static func isNegative(_ word: String) -> Bool { negatives.contains(word) || word.hasSuffix("n't") }

    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func equivalent(_ left: String, _ right: String, _ preferred: Set<String>) -> Bool {
        left == right || (preferred.contains(right) && left.count >= 4 && right.count >= 4 && editDistance(left, right) <= 2)
    }

    private static func alignment(_ before: [Token], _ after: [Token], preferredTerms: Set<String>) -> [(Int, Int)] {
        let width = after.count + 1
        var scores = [UInt32](repeating: 0, count: (before.count + 1) * width)
        func weight(_ i: Int, _ j: Int) -> UInt32 {
            // Prefer coherent phrases over stealing an isolated "A" or "agreed"
            // from a surviving long answer to satisfy an omitted short answer.
            var value: UInt32 = 8
            if i > 0, j > 0, equivalent(before[i - 1].word, after[j - 1].word, preferredTerms) { value += 2 }
            if i + 1 < before.count, j + 1 < after.count, equivalent(before[i + 1].word, after[j + 1].word, preferredTerms) { value += 2 }
            return value
        }
        if !before.isEmpty, !after.isEmpty {
            for i in 1...before.count {
                for j in 1...after.count {
                    let skip = max(scores[(i - 1) * width + j], scores[i * width + j - 1])
                    scores[i * width + j] = equivalent(before[i - 1].word, after[j - 1].word, preferredTerms)
                        ? max(skip, scores[(i - 1) * width + j - 1] + weight(i - 1, j - 1)) : skip
                }
            }
        }
        var i = before.count, j = after.count
        var result: [(Int, Int)] = []
        while i > 0, j > 0 {
            if equivalent(before[i - 1].word, after[j - 1].word, preferredTerms),
               scores[i * width + j] == scores[(i - 1) * width + j - 1] + weight(i - 1, j - 1) {
                result.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if scores[(i - 1) * width + j] >= scores[i * width + j - 1] { i -= 1 }
            else { j -= 1 }
        }
        return result.reversed()
    }

    // ASR can split a preferred name ("mini max"). Join only horizontally
    // separated fragments so punctuation and answer boundaries stay protected.
    static func recognizedTerms(in text: String, candidates: Set<String>) -> [Token] {
        let tokens = tokens(text)
        let source = text as NSString
        let candidates = candidates.filter { $0.count >= 4 }.sorted()
        var result: [Token] = []
        var index = 0
        while index < tokens.count {
            var joined = false
            for width in [3, 2] where index + width <= tokens.count {
                let fragments = tokens[index..<(index + width)]
                guard fragments.allSatisfy({ $0.word.count >= 2 }),
                      zip(fragments, fragments.dropFirst()).allSatisfy({ left, right in
                          let start = NSMaxRange(left.range)
                          guard right.range.location > start else { return false }
                          let gap = source.substring(with: NSRange(location: start, length: right.range.location - start))
                          return gap.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
                      }) else { continue }
                let phrase = fragments.map(\.word).joined()
                if let term = candidates.first(where: { editDistance(phrase, $0) <= 1 }) {
                    result.append(Token(word: term, range: NSRange(location: tokens[index].range.location, length: NSMaxRange(tokens[index + width - 1].range) - tokens[index].range.location)))
                    index += width; joined = true; break
                }
            }
            if !joined { result.append(tokens[index]); index += 1 }
        }
        return result
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        guard abs(a.count - b.count) <= 2 else { return 3 }
        let right = Array(b)
        var row = Array(0...right.count)
        for (i, left) in a.enumerated() {
            var diagonal = row[0]; row[0] = i + 1
            for (j, character) in right.enumerated() {
                let old = row[j + 1]
                row[j + 1] = min(row[j] + 1, old + 1, diagonal + (left == character ? 0 : 1))
                diagonal = old
            }
        }
        return row.last ?? 0
    }
}
