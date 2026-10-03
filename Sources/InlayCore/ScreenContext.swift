import CoreGraphics
import Foundation
import Vision

/// Recognition hints drawn from text visible in the window being dictated into.
/// Recognized text stays on the Mac; only a short list of unusual terms (names,
/// identifiers, product words) is sent to the server as Whisper vocabulary.
public enum ScreenContext {
    public static let maximumTerms = 40
    public static let maximumTermBytes = 64
    /// Bounds ranking work for dense windows; text beyond this is ignored.
    public static let maximumTokens = 3_000

    /// On-device text recognition. Language correction is off so unusual names keep
    /// their on-screen spelling instead of being "fixed" into dictionary words.
    public static func recognizeLines(in image: CGImage) async throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: image).perform([request])
            try Task.checkCancellation()
        } onCancel: { request.cancel() }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.4 else { return nil }
            return candidate.string
        }
    }

    /// Rank words that a speech model is unlikely to spell correctly on its own.
    /// `isKnownWord` reports dictionary words. Proper names are recognized when only
    /// their capitalized form is known; other known words are kept only when
    /// capitalized mid-sentence and repeated. Emails, paths, web addresses, and long
    /// numbers are never returned.
    public static func terms(fromLines lines: [String], isKnownWord: (String) -> Bool,
                             limit: Int = maximumTerms) -> [String] {
        struct Candidate {
            var spellings: [String: Int] = [:]
            var count = 0
            var score = 0
            var first: Int
            var rank: Int { score + (count >= 4 ? 2 : count >= 2 ? 1 : 0) }
            /// The most frequent on-screen spelling, ties broken alphabetically.
            var term: String {
                spellings.max { left, right in
                    left.value != right.value ? left.value < right.value : left.key > right.key
                }?.key ?? ""
            }
        }
        var candidates: [String: Candidate] = [:]
        var order = 0
        var known: [String: Bool] = [:]
        let knownWord = { (word: String) -> Bool in
            if let cached = known[word] { return cached }
            let result = isKnownWord(word)
            known[word] = result
            return result
        }
        var remaining = maximumTokens
        lines: for line in lines {
            var sentenceStart = true
            for chunk in line.split(whereSeparator: \.isWhitespace) {
                defer { sentenceStart = chunk.last.map { ".!?:".contains($0) } ?? false }
                // Skip emails, URLs, domains, and paths whole rather than leaking their parts.
                guard !chunk.contains(where: { "@/\\".contains($0) }), !isWebAddress(chunk) else { continue }
                for (index, match) in chunk.matches(of: tokenPattern).enumerated() {
                    remaining -= 1
                    if remaining < 0 { break lines }
                    guard let token = normalized(String(match.output)),
                          let score = score(token, sentenceStart: sentenceStart && index == 0, isKnownWord: knownWord)
                    else { continue }
                    let key = token.lowercased()
                    var candidate = candidates[key] ?? Candidate(first: order)
                    order += 1
                    candidate.spellings[token, default: 0] += 1
                    candidate.count += 1
                    candidate.score = max(candidate.score, score)
                    candidates[key] = candidate
                }
            }
        }
        return candidates.values
            .filter { $0.rank >= 2 }
            .sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.first < $1.first }
            .prefix(limit)
            .map(\.term)
    }

    /// Identifier-like runs: letters and digits joined by dots, underscores, hyphens, or apostrophes.
    private static let tokenPattern = #/[\p{L}\p{N}](?:[\p{L}\p{M}\p{N}_+#]|[.\-'’](?=[\p{L}\p{N}]))*/#

    private static let domainPattern = #/(?:[\p{L}\p{N}-]+\.)+([\p{L}]{2,24})/#
    private static let commonTopLevelDomains: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "me", "so", "sh", "gg", "ly", "tv", "xyz", "info", "biz",
        "gov", "edu", "us", "uk", "ca", "au", "nz", "de", "fr", "nl", "eu", "in", "design", "site", "tech", "cloud",
    ]
    private static let fileExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "csv", "go", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "lock", "log",
        "m", "md", "mjs", "pdf", "plist", "png", "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt",
        "xml", "yaml", "yml",
    ]

    /// Domains are dropped whether written with a port, query, or fragment. A lowercase
    /// dotted name counts as a domain unless it ends in a source-file extension, so
    /// identifiers such as whisper.cpp, README.md, or Stripe.Event survive.
    private static func isWebAddress(_ chunk: Substring) -> Bool {
        let host = chunk.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            .split(whereSeparator: { ":?#".contains($0) }).first.map(String.init) ?? ""
        if host.lowercased().hasPrefix("www.") { return true }
        guard let match = host.wholeMatch(of: domainPattern) else { return false }
        let suffix = String(match.output.1).lowercased()
        if commonTopLevelDomains.contains(suffix) && !fileExtensions.contains(suffix) { return true }
        return host == host.lowercased() && !fileExtensions.contains(suffix)
    }

    private static func normalized(_ token: String) -> String? {
        var token = token
        for suffix in ["'s", "’s"] where token.hasSuffix(suffix) { token.removeLast(2) }
        guard token.count >= 2, token.utf8.count <= maximumTermBytes else { return nil }
        let letters = token.filter(\.isLetter).count, digits = token.filter(\.isNumber).count
        // Long digit runs are usually codes, prices, phone or account numbers.
        guard letters >= 2, digits < 4 else { return nil }
        // Quantities with units, ordinals, and times: 25mg, 2nd, 10am.
        if token.lowercased().wholeMatch(of: #/\d+[a-z]{1,3}/#) != nil { return nil }
        return token
    }

    private static func score(_ token: String, sentenceStart: Bool, isKnownWord: (String) -> Bool) -> Int? {
        let characters = Array(token)
        var score = 0
        // camelCase, PascalCase with an inner capital, or a lowercase brand such as iPhone.
        if zip(characters, characters.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) { score += 3 }
        // Identifiers joined by underscores or dots, such as snake_case or whisper.cpp.
        if zip(zip(characters, characters.dropFirst()), characters.dropFirst(2))
            .contains(where: { $0.0.isLetter && "_.".contains($0.1) && $1.isLetter }) { score += 3 }
        if token.contains(where: \.isNumber) { score += 2 }
        var word = 0
        for part in token.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) where part.count >= 3 {
            let part = String(part), lower = part.lowercased()
            if part.allSatisfy({ !$0.isLowercase }) {
                // Spell checkers accept any all-caps word; only the lowercase form says whether it is ordinary.
                if !isKnownWord(lower) { word = max(word, 3) }
            } else if !isKnownWord(part) {
                if !isKnownWord(lower) { word = max(word, 3) }
            } else if part.first?.isUppercase == true, !isKnownWord(lower) {
                // Known only when capitalized: a name such as Siobhan or Priya.
                word = max(word, 2)
            }
        }
        score += word
        // A known word capitalized mid-sentence may be a name; it ranks low and
        // needs repetition to be kept.
        if score == 0, !sentenceStart, characters[0].isUppercase, token.filter(\.isLetter).count >= 3 { score += 1 }
        return score > 0 ? score : nil
    }
}
