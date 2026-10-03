import Foundation

public struct DictionaryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var term: String
    public var aliases: [String]
    public var isPriority: Bool

    public init(id: String = UUID().uuidString, term: String, aliases: [String] = [], isPriority: Bool = false) {
        self.id = id
        self.term = term
        self.aliases = aliases
        self.isPriority = isPriority
    }

    private enum CodingKeys: String, CodingKey { case id, term, aliases, isPriority }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  term: try values.decode(String.self, forKey: .term),
                  aliases: values.contains(.aliases) ? try values.decode([String].self, forKey: .aliases) : [],
                  isPriority: values.contains(.isPriority) ? try values.decode(Bool.self, forKey: .isPriority) : false)
        if let error = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error))
        }
    }

    public var validationError: String? {
        guard DictionaryValidation.validText(id, limit: 128) else { return "Each dictionary word needs a nonempty id of at most 128 characters." }
        guard DictionaryValidation.validText(term, limit: 128) else { return "Dictionary words must be single-line, nonempty text of at most 128 characters, without surrounding whitespace." }
        guard aliases.count <= 8 else { return "Each dictionary word can have up to 8 corrections." }
        var seen = Set([DictionaryValidation.key(term)])
        for alias in aliases {
            guard DictionaryValidation.validText(alias, limit: 128) else { return "Corrections must be single-line, nonempty text of at most 128 characters, without surrounding whitespace." }
            guard seen.insert(DictionaryValidation.key(alias)).inserted else {
                return "Corrections for \(term) must be unique and different from its preferred spelling. Capitalization is corrected automatically."
            }
        }
        return nil
    }
}

public struct DictionaryList: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var entries: [DictionaryEntry]

    public init(id: String = UUID().uuidString, name: String, entries: [DictionaryEntry] = []) {
        self.id = id
        self.name = name
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case id, name, entries }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  entries: values.contains(.entries) ? try values.decode([DictionaryEntry].self, forKey: .entries) : [])
        if let error = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error))
        }
    }

    public var validationError: String? {
        guard DictionaryValidation.validText(id, limit: 128) else { return "Each dictionary list needs a nonempty id of at most 128 characters." }
        guard DictionaryValidation.validText(name, limit: 80) else { return "Dictionary list names must be single-line, nonempty text of at most 80 characters, without surrounding whitespace." }
        guard entries.count <= PersonalDictionary.maximumEntries else { return "The dictionary can contain up to \(PersonalDictionary.maximumEntries) words in total." }
        guard Set(entries.map(\.id)).count == entries.count else { return "Dictionary word ids must be unique." }
        return entries.lazy.compactMap(\.validationError).first
    }
}

/// Every list is active. Only preferred spellings and explicitly supplied corrections
/// are applied; there is no fuzzy matching, learned substitution, or generative rewrite.
public struct PersonalDictionary: Codable, Equatable, Sendable {
    public var lists: [DictionaryList]

    public static let maximumEntries = 500
    public static let `default` = PersonalDictionary(lists: [
        DictionaryList(id: "personal", name: "Personal", entries: [
            DictionaryEntry(id: "minimax", term: "MiniMax"),
            DictionaryEntry(id: "codex", term: "Codex"),
        ]),
    ])

    public init(lists: [DictionaryList] = []) {
        self.lists = lists
    }

    private enum CodingKeys: String, CodingKey { case lists }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(lists: try values.decode([DictionaryList].self, forKey: .lists))
        if let error = validationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error))
        }
    }

    public var validationError: String? {
        guard lists.count <= 32 else { return "The dictionary can contain up to 32 lists." }
        guard Set(lists.map(\.id)).count == lists.count else { return "Dictionary list ids must be unique." }
        if let error = lists.lazy.compactMap(\.validationError).first { return error }
        let entries = lists.flatMap(\.entries)
        guard entries.count <= Self.maximumEntries else { return "The dictionary can contain up to \(Self.maximumEntries) words in total." }
        guard Set(entries.map(\.id)).count == entries.count else { return "Dictionary word ids must be unique across all lists." }
        var spellings: [String: String] = [:]
        for entry in entries {
            for spelling in [entry.term] + entry.aliases {
                let key = DictionaryValidation.key(spelling)
                if let existing = spellings[key], existing != entry.term {
                    return "\(spelling) maps to both \(existing) and \(entry.term). Each spelling can have only one preferred word across all lists."
                }
                spellings[key] = entry.term
            }
        }
        return nil
    }

    /// Priority affects hints only. Preserve list order within each priority group;
    /// aliases never become hints that could reinforce a wrong spelling.
    public var vocabularyTerms: [String] {
        guard validationError == nil else { return [] }
        let entries = lists.flatMap(\.entries)
        return Self.uniqueTerms((entries.filter(\.isPriority) + entries.filter { !$0.isPriority }).map(\.term))
    }

    /// Freeform terms only guide speech recognition; adding them does not install
    /// replacements or make them protected dictionary terms during proofreading.
    public func recognitionVocabularyTerms(_ freeform: String) -> [String] {
        let extras = freeform.components(separatedBy: CharacterSet(charactersIn: ",").union(.newlines))
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return Self.uniqueTerms(vocabularyTerms + extras)
    }

    private static func uniqueTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert(DictionaryValidation.key($0)).inserted }
    }

    /// When bounded, keep the entire source if replacements would exceed the
    /// output budget. Never return a partial transcript or partial dictionary pass.
    public func apply(to text: String, maximumOutputUTF8Bytes: Int? = nil) -> String {
        guard !text.isEmpty, validationError == nil else { return text }
        var replacements: [String: String] = [:]
        // Swift String equality is canonically equivalent, so a Set<String>
        // would discard one of the composed/decomposed regex spellings.
        var spellings: [Data: String] = [:]
        for entry in lists.flatMap(\.entries) {
            for spelling in [entry.term] + entry.aliases {
                replacements[DictionaryValidation.key(spelling)] = entry.term
                // Match both canonical forms without normalizing any surrounding text.
                for form in [spelling.precomposedStringWithCanonicalMapping, spelling.decomposedStringWithCanonicalMapping] {
                    spellings[Data(form.utf8)] = form
                }
            }
        }
        guard !spellings.isEmpty else { return text }
        let alternatives = spellings.values.sorted {
            $0.utf16.count == $1.utf16.count ? $0 < $1 : $0.utf16.count > $1.utf16.count
        }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        // Include marks and connector punctuation so accents and identifiers such as
        // codex_plugin are never partially rewritten. Longest phrases win at a position.
        let word = "[\\p{L}\\p{M}\\p{N}\\p{Pc}\\u200C\\u200D]"
        guard let pattern = try? NSRegularExpression(pattern: "(?<!\(word))(?:\(alternatives))(?!\(word))", options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        let characterBoundaries = Set(text.indices).union([text.endIndex])
        // Build from the original text once. Replacement output is never matched again.
        var result = ""
        result.reserveCapacity(min(text.utf8.count, max(0, maximumOutputUTF8Bytes ?? text.utf8.count)))
        var outputBytes = 0
        var cursor = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text),
                  characterBoundaries.contains(range.lowerBound), characterBoundaries.contains(range.upperBound),
                  let replacement = replacements[DictionaryValidation.key(String(text[range]))] else { continue }
            let unchanged = text[cursor..<range.lowerBound]
            let nextBytes = outputBytes + unchanged.utf8.count + replacement.utf8.count
            if let maximumOutputUTF8Bytes, nextBytes > maximumOutputUTF8Bytes { return text }
            result.append(contentsOf: unchanged)
            result.append(replacement)
            outputBytes = nextBytes
            cursor = range.upperBound
        }
        let remaining = text[cursor...]
        if let maximumOutputUTF8Bytes, outputBytes + remaining.utf8.count > maximumOutputUTF8Bytes { return text }
        result.append(contentsOf: remaining)
        return result
    }
}

private enum DictionaryValidation {
    static func validText(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.count <= limit
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil
    }

    static func key(_ text: String) -> String {
        text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
