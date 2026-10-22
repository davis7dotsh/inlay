import CoreGraphics
import Foundation
import Vision

/// Proofreading hints drawn from text visible in the window being dictated into.
/// Recognized text stays on the Mac; only a short list of unusual terms (names,
/// identifiers, product words) is sent to the server as Qwen cleanup hints.
public enum ScreenContext {
    public static let maximumTerms = 40
    public static let maximumTermBytes = 64
    /// Bounds ranking work for dense windows; text beyond this is ignored.
    public static let maximumTokens = 3_000
    /// Bounds spell checks spent reading long segments as words (see `isWordLike`); a
    /// window of random strings would otherwise cost seconds. Past it they fail closed.
    private static let maximumSegmentChecks = 1_000

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

    /// Rank words that speech recognition is unlikely to spell correctly on its own.
    /// `isKnownWord` reports dictionary words. Proper names are recognized when only
    /// their capitalized form is known; other known words are kept only when
    /// capitalized mid-sentence and repeated. Emails, paths, web addresses, and long
    /// numbers are never returned, nor is anything shaped like a credential.
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
        func knownWord(_ word: String) -> Bool {
            if let cached = known[word] { return cached }
            let result = isKnownWord(word)
            known[word] = result
            return result
        }
        var segmentChecks = maximumSegmentChecks
        func segmentWord(_ word: String) -> Bool {
            if known[word] == nil { segmentChecks -= 1 }
            return segmentChecks >= 0 ? knownWord(word) : known[word] ?? false
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
                    guard let token = normalized(String(match.output), isKnownWord: segmentWord),
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
    private static let countryDomainExtensions: Set<String> = ["cc", "md", "py", "rs"]
    private static let fileExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "csv", "go", "h", "hpp", "html", "java", "js", "json", "jsx", "kt", "lock", "log",
        "m", "md", "mjs", "pdf", "plist", "png", "py", "rb", "rs", "sql", "swift", "toml", "ts", "tsx", "txt",
        "xml", "yaml", "yml",
    ]

    /// A chunk with query or assignment syntax is dropped whole, and so is one holding
    /// any domain: a dotted name ending in a common top-level domain or a lowercase
    /// final label, or one followed by a port. Source-file names such as whisper.cpp
    /// or main.swift:12:5 and identifiers such as Stripe.Event survive.
    private static func isWebAddress(_ chunk: Substring) -> Bool {
        let text = String(chunk), lower = text.lowercased()
        let core = text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        if core.contains(where: { "?#=&".contains($0) }) || lower.contains("www.") || lower.contains("xn--") {
            return true
        }
        for match in text.matches(of: domainPattern) {
            let label = String(match.output.1), suffix = label.lowercased()
            // Some extensions are also country domains (Bank.MD, shop.rs); hosts cannot
            // hold underscores, so only snake_case names such as setup_tools.py keep the
            // exception. README.md is lost as a hint rather than risk leaking a domain.
            if countryDomainExtensions.contains(suffix) {
                if text[..<match.range.lowerBound].last == "_", match.output.0.count(where: { $0 == "." }) == 1 {
                    continue
                }
                return true
            }
            if fileExtensions.contains(suffix) { continue }
            // A lowercase first or final label covers unlisted top-level domains in any
            // case (Acme.email, portal.Travel); member names such as Stripe.Event remain.
            let first = match.output.0.prefix { $0 != "." }
            if commonTopLevelDomains.contains(suffix) || label == suffix || first == first.lowercased()
                || text[match.range.upperBound...].first == ":" { return true }
        }
        return false
    }

    private static func normalized(_ token: String, isKnownWord: (String) -> Bool) -> String? {
        var token = token
        for suffix in ["'s", "’s"] where token.hasSuffix(suffix) { token.removeLast(2) }
        guard token.count >= 2, token.utf8.count <= maximumTermBytes else { return nil }
        let letters = token.filter(\.isLetter).count, digits = token.filter(\.isNumber).count
        // Long digit runs are usually codes, prices, phone or account numbers.
        guard letters >= 2, digits < 4 else { return nil }
        // Quantities with units, ordinals, and times: 25mg, 2nd, 10am.
        if token.lowercased().wholeMatch(of: #/\d+[a-z]{1,3}/#) != nil { return nil }
        return isCredential(token, isKnownWord: isKnownWord) ? nil : token
    }

    /// Vendor key prefixes no identifier starts with, followed by at least eight more characters.
    private static let credentialPrefixes = [
        "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "gldt-", "sk-proj-", "sk-ant-",
        "sk-svcacct-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "pk_live_", "pk_test_", "whsec_", "xoxa-",
        "xoxb-", "xoxp-", "xoxr-", "xoxs-", "xapp-", "pypi-AgE", "SG.", "eyJ", "AIza", "ya29.", "shpat_",
        "shpca_", "shppa_", "shpss_", "dop_v1_", "lin_api_", "figd_", "ATATT",
    ]
    /// Vendor key prefixes that also start ordinary identifiers (npm_config_prefix,
    /// hf_hub_download, gsk_renderer_new); they count only before a long unbroken tail.
    private static let sharedCredentialPrefixes = ["sk-", "hf_", "npm_", "gsk_", "xai-", "r8_"]

    /// Fails closed: a hint that might be a secret is dropped. Beyond listed vendor
    /// prefixes and AWS key IDs, shapes no name or ordinary identifier has catch
    /// unlisted vendors, checked per segment between `_`, `-`, or `.`. Of 12 or more
    /// characters: letters under 15% vowels (words run far higher, random base62 near
    /// 19%). Of 16 or more: adjacent characters switching between lowercase, uppercase,
    /// and digits at half or more of positions, as random base62 does (short camelCase
    /// words such as onMouseUpCapture switch less); or two humps of one capital or digit
    /// and one lowercase letter with no vowel, such as Qz, where short camelCase words
    /// (Of, To, By) carry one. Of 24 or more: no camelCase hump at all. Long segments
    /// must also read as words (see `isWordLike`): 12 or more characters when joined
    /// to other segments, 8 or more in a joined token of 24 or more characters, and 24
    /// or more alone, since vendor tails follow a prefix while long single names such
    /// as Brzeczyszczykiewicz stand alone. In a joined token of 24 or more characters,
    /// the shorter segments must read as words together.
    private static func isCredential(_ token: String, isKnownWord: (String) -> Bool) -> Bool {
        if credentialPrefixes.contains(where: { token.hasPrefix($0) && token.count >= $0.count + 8 }) { return true }
        if sharedCredentialPrefixes.contains(where: { prefix in
            let tail = token.dropFirst(prefix.count)
            return token.hasPrefix(prefix) && tail.count >= 20 && !tail.contains(where: { "_-".contains($0) })
        }) { return true }
        if token.wholeMatch(of: #/A(?:KIA|SIA|GPA|IDA|ROA|NPA|IPA|NVA)[A-Z0-9]{12,}/#) != nil { return true }
        let segments = token.split(whereSeparator: { "_-.".contains($0) })
        let isShaped = segments.contains { segment in
            let characters = Array(segment)
            guard characters.count >= 12 else { return false }
            let letters = characters.filter(\.isLetter)
            if Double(letters.filter { "aeiouAEIOU".contains($0) }.count) < 0.15 * Double(letters.count) { return true }
            guard characters.count >= 16 else { return false }
            let pairs = zip(characters, characters.dropFirst())
            if characters.count >= 24, !pairs.contains(where: { $0.isLowercase && $1.isUppercase }) { return true }
            let kind = { (character: Character) in character.isLowercase ? 0 : character.isUppercase ? 1 : 2 }
            if Double(pairs.filter { kind($0) != kind($1) }.count) >= 0.5 * Double(characters.count - 1) { return true }
            let voiceless = characters.indices.dropLast().filter { index in
                !characters[index].isLowercase && characters[index + 1].isLowercase
                    && (index + 2 == characters.count || !characters[index + 2].isLowercase)
                    && !"aeiouyAEIOUY".contains(characters[index]) && !"aeiouy".contains(characters[index + 1])
            }
            return voiceless.count >= 2
        }
        // Random tails split into short segments (acme_live_qwertyuiop1_asdfghjklz2) slip
        // under 12 characters, so long tokens check each segment of 8 or more; shorter
        // ones are mostly abbreviations such as KEVENT or netsnmp, so together, once
        // they hold 12 or more letters, they must read as words in order, as
        // use_screen_context_hints does and acme_live_qzxjkvb_nmzqjkv does not. Checked
        // last: the shapes above cost no spell checks.
        let wordLength = segments.count == 1 ? 24 : token.count >= 24 ? 8 : 12
        if isShaped || segments.contains(where: { segment in
            segment.count >= wordLength && !isWordLike(coveredLetters(segment, isKnownWord: isKnownWord))
        }) { return true }
        guard token.count >= 24 else { return false }
        let shortLetters = segments.filter { $0.count < wordLength }.flatMap { coveredLetters($0, isKnownWord: isKnownWord) }
        // Shorter joins skip the coverage share but never the run limit, so at most
        // five consecutive letters of a long token stay unchecked whatever the split.
        return shortLetters.count >= 12 ? !isWordLike(shortLetters) : longestUncoveredRun(shortLetters) > 5
    }

    /// camelCase humps, acronyms, and digit runs: maximumScreenContextTerms gives
    /// maximum, Screen, Context, Terms; FocusedUIElement gives Focused, UI, Element.
    private static let subwordPattern = #/\p{Lu}?\p{Ll}+|\p{Lu}+(?!\p{Ll})|\p{N}+/#

    /// Whether letters read as words: known subwords cover at least half of them and
    /// leave no more than five in a row uncovered, so a known word cannot carry a
    /// random run beside it (interfaceqzxjkvbn). A prefix such as NS or k costs little
    /// in a long name, while random tails, made of short humps and unknown runs, fall
    /// far short.
    private static func isWordLike(_ covered: [Bool]) -> Bool {
        2 * covered.count(where: { $0 }) >= covered.count && longestUncoveredRun(covered) <= 5
    }

    private static func longestUncoveredRun(_ covered: [Bool]) -> Int {
        var run = 0, longestRun = 0
        for isCovered in covered {
            run = isCovered ? 0 : run + 1
            longestRun = max(longestRun, run)
        }
        return longestRun
    }

    /// Whether each of the segment's letters, in order, lies in a known subword of three
    /// or more letters; shorter subwords and uncased letters are uncovered. An unknown
    /// subword of eight or more letters is covered by the known words of five to twelve
    /// letters it splits into, as fullscreenchange or PRESERVEASPECTRATIO are; random
    /// runs rarely hold them.
    private static func coveredLetters(_ segment: Substring, isKnownWord: (String) -> Bool) -> [Bool] {
        var covered = [Bool](repeating: false, count: segment.count)
        for match in segment.matches(of: subwordPattern) {
            let part = Array(match.output), start = segment.distance(from: segment.startIndex, to: match.range.lowerBound)
            guard part.count >= 3, part[0].isLetter else { continue }
            let word = String(part), lower = word.lowercased()
            // Spell checkers accept any all-caps word; only the lowercase form says whether it is ordinary.
            if part.allSatisfy({ !$0.isLowercase }) ? isKnownWord(lower) : isKnownWord(word) || isKnownWord(lower) {
                covered.replaceSubrange(start..<(start + part.count), with: repeatElement(true, count: part.count))
                continue
            }
            guard part.count >= 8 else { continue }
            // best[end]: most letters of part[..<end] covered by known words, the last
            // of them starting at wordStart[end] when it ends at end.
            var best = [Int](repeating: 0, count: part.count + 1), wordStart = [Int?](repeating: nil, count: part.count + 1)
            for end in 1...part.count {
                best[end] = best[end - 1]
                for length in 5...12 where length <= end && best[end - length] + length > best[end] {
                    if isKnownWord(String(part[(end - length)..<end]).lowercased()) {
                        best[end] = best[end - length] + length
                        wordStart[end] = end - length
                    }
                }
            }
            var end = part.count
            while end > 0 {
                guard let wordStart = wordStart[end] else { end -= 1; continue }
                covered.replaceSubrange((start + wordStart)..<(start + end), with: repeatElement(true, count: end - wordStart))
                end = wordStart
            }
        }
        return zip(segment, covered).filter { $0.0.isLetter }.map(\.1)
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
