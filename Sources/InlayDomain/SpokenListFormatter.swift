import Foundation

public struct SpokenListContext: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Equatable, Sendable {
        case numbered
        case bulleted
    }

    public let style: Style
    public let nextNumber: Int

    public init(style: Style, nextNumber: Int = 1) {
        self.style = style
        self.nextNumber = max(0, nextNumber)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: try values.decode(Style.self, forKey: .style),
                  nextNumber: try values.decode(Int.self, forKey: .nextNumber))
    }
}

public struct FormattedDictation: Equatable, Sendable {
    public let text: String
    public let context: SpokenListContext?
    public let containsList: Bool
    public let endsWithList: Bool
    public let continuesPreviousList: Bool
    public let endedList: Bool
    public let isControlOnly: Bool
    public let consumedControls: [ListControlSpan]
    public let formattingRejectionReason: String?

    public func replacingText(_ text: String) -> FormattedDictation {
        FormattedDictation(text: text, context: context, containsList: containsList,
                          endsWithList: endsWithList, continuesPreviousList: continuesPreviousList,
                          endedList: endedList, isControlOnly: isControlOnly,
                          consumedControls: consumedControls, formattingRejectionReason: formattingRejectionReason)
    }
}

/// UTF-16 ranges into the recognized source, suitable for persisted diagnostics.
public struct ListControlSpan: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
}

/// A local, deterministic dictation grammar, not a prose rewrite. The caller owns
/// which field/caret the context belongs to and commits it only after insertion.
public enum SpokenListFormatter {
    public static func format(_ text: String, context initialContext: SpokenListContext? = nil) -> FormattedDictation {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FormattedDictation(text: "", context: initialContext, containsList: false, endsWithList: false,
                                      continuesPreviousList: false, endedList: false, isControlOnly: false,
                                      consumedControls: [], formattingRejectionReason: nil)
        }

        let events = scan(text)
        let inferred = inferredMarkers(events, in: text)
        let containsInlineCandidates = events.contains { $0.evidence == .inlineSeries }
        var context = initialContext
        var usesOriginalContext = initialContext != nil
        var pieces: [(text: String, isList: Bool)] = []
        var body = ""
        var cursor = text.startIndex
        var containsList = false
        var continuesPreviousList = false
        var endedList = false
        var consumedControl = false
        var awaitingMarkedItem = false
        var bodyStart = text.startIndex
        var controls: [Range<String.Index>] = []
        var numberMarkers: [(range: Range<String.Index>, number: Int)] = []
        var emittedContent: [String] = []
        var pendingSourceNumber: Int?

        func consumeControl(_ range: Range<String.Index>) {
            controls.append(range)
        }

        func flush() {
            let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
            body = ""
            awaitingMarkedItem = false
            guard !content.isEmpty else { return }
            guard let current = context else {
                pieces.append((content, false))
                emittedContent += contentTokens(content)
                return
            }
            let item = itemText(content)
            guard !item.isEmpty else { return }
            if pieces.isEmpty && usesOriginalContext && initialContext?.style == current.style {
                continuesPreviousList = true
            }
            switch current.style {
            case .numbered:
                pieces.append(("\(current.nextNumber). \(item)", true))
                if pendingSourceNumber != nil { emittedContent.append(numberToken(current.nextNumber)) }
                let next = current.nextNumber == Int.max ? Int.max : current.nextNumber + 1
                context = SpokenListContext(style: .numbered, nextNumber: next)
            case .bulleted:
                pieces.append(("- \(item)", true))
            }
            emittedContent += contentTokens(item)
            pendingSourceNumber = nil
            containsList = true
        }

        for (index, event) in events.enumerated() {
            body += text[cursor..<event.range.lowerBound]
            cursor = event.range.upperBound
            switch event.action {
            case .item(let marker):
                let next = index + 1 < events.count ? events[index + 1].range.lowerBound : text.endIndex
                let followingBody = String(text[event.range.upperBound..<next])
                let hasBody = followingBody.contains(where: { $0.isLetter || $0.isNumber })
                // A bare answer such as "24." is content even in an active
                // list. Only actual verbal controls may have no item body.
                if case .number = marker, !hasBody {
                    body += text[event.range]
                    continue
                }
                if event.evidence == .series, !containsNonCountingContent(followingBody) {
                    body += text[event.range]
                    continue
                }
                let contextSupportsMarker = context != nil && event.evidence != .inlineSeries && event.evidence != .unanchoredSeries
                    && event.evidence != .copularSeries
                    && !(event.evidence == .series && containsInlineCandidates && !inferred.contains(index))
                guard contextSupportsMarker
                    || event.evidence == .explicit || event.evidence == .numeric || inferred.contains(index) else {
                    body += text[event.range]
                    continue
                }
                flush()
                switch marker {
                case .number(let number):
                    context = SpokenListContext(style: .numbered, nextNumber: number)
                    numberMarkers.append((event.range, number))
                    pendingSourceNumber = number
                case .bullet:
                    context = SpokenListContext(style: .bulleted)
                    consumeControl(event.range)
                case .next:
                    if context == nil { context = SpokenListContext(style: .numbered) }
                    consumeControl(event.range)
                }
                consumedControl = true
                awaitingMarkedItem = true
                bodyStart = event.range.upperBound
            case .start(let style):
                flush()
                context = SpokenListContext(style: style ?? .numbered)
                usesOriginalContext = false
                consumedControl = true
                consumeControl(event.range)
                bodyStart = event.range.upperBound
            case .resume(let style):
                // Only explicit resumption licenses discarding dictation/tool
                // chatter. Never remove these words from an actual marked item.
                if !containsList && !awaitingMarkedItem {
                    let removed = metaPreludeRanges(in: text, range: bodyStart..<event.range.lowerBound)
                    for range in removed { consumeControl(range) }
                    body = removing(removed, from: text, within: bodyStart..<event.range.lowerBound)
                }
                flush()
                if let style, style != context?.style {
                    context = SpokenListContext(style: style)
                    usesOriginalContext = false
                } else if context == nil {
                    context = SpokenListContext(style: style ?? .numbered)
                }
                consumedControl = true
                consumeControl(event.range)
                bodyStart = event.range.upperBound
            case .end:
                flush()
                context = nil
                usesOriginalContext = false
                endedList = true
                consumedControl = true
                consumeControl(event.range)
                bodyStart = event.range.upperBound
            }
        }
        body += text[cursor...]
        flush()

        // Ordinary prose stays byte-for-byte intact, including its paragraphs.
        if !consumedControl && initialContext == nil {
            return FormattedDictation(text: text, context: nil, containsList: false, endsWithList: false,
                                      continuesPreviousList: false, endedList: false, isControlOnly: false,
                                      consumedControls: [], formattingRejectionReason: nil)
        }
        var output = ""
        for (index, piece) in pieces.enumerated() {
            if index > 0 {
                output += pieces[index - 1].isList && piece.isList ? "\n" : "\n\n"
            }
            output += piece.text
        }
        if output.isEmpty && consumedControl && usesOriginalContext && context?.style == initialContext?.style && context != nil {
            continuesPreviousList = true
        }
        // Check the formatting boundary before Qwen can compare against an
        // already-damaged transcript. Only recorded controls may disappear;
        // numbered markers are normalized to the value actually emitted.
        let sourceContent = sourceContentTokens(text, controls: controls, numberMarkers: numberMarkers)
        guard sourceContent == emittedContent else {
            return FormattedDictation(text: text, context: initialContext, containsList: false, endsWithList: false,
                                      continuesPreviousList: false, endedList: false, isControlOnly: false,
                                      consumedControls: [], formattingRejectionReason: "List formatting would change dictated content; kept the original transcript.")
        }
        return FormattedDictation(text: output, context: context, containsList: containsList,
                                  endsWithList: pieces.last?.isList == true,
                                  continuesPreviousList: continuesPreviousList, endedList: endedList,
                                  isControlOnly: consumedControl && output.isEmpty,
                                  consumedControls: controls.map { range in
                                      let range = NSRange(range, in: text)
                                      return ListControlSpan(location: range.location, length: range.length)
                                  }, formattingRejectionReason: nil)
    }

    private enum Action {
        case start(SpokenListContext.Style?)
        case resume(SpokenListContext.Style?)
        case end
        case item(Marker)
    }

    private enum Marker {
        case number(Int)
        case next
        case bullet
    }

    private enum Evidence {
        case explicit
        case numeric
        case series
        case unanchoredSeries
        case inlineSeries
        case copularSeries
        case contextOnly
    }

    private struct Event {
        let range: Range<String.Index>
        let action: Action
        let evidence: Evidence
    }

    private struct Token {
        let value: String
        let range: Range<String.Index>
        var isBoundary: Bool {
            [".", "!", "?", ";", ":", "\n"].contains(value)
                || (value.hasSuffix(".") && !["dr.", "mr.", "mrs.", "ms.", "st."].contains(value))
        }
    }

    private struct Match {
        let end: Int
        let action: Action
        let evidence: Evidence
    }

    /// Token ranges let us preserve item bodies instead of reconstructing prose
    /// from words. Decimal numbers, dates, times, and common abbreviations remain
    /// single tokens, so their punctuation never becomes an item boundary.
    private static func tokenize(_ text: String) -> [Token] {
        var result: [Token] = []
        var cursor = text.startIndex
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "jr", "sr", "st", "vs", "etc", "e.g", "i.e"]
        while cursor < text.endIndex {
            let start = cursor
            let character = text[cursor]
            cursor = text.index(after: cursor)
            if character.isWhitespace {
                if character.isNewline { result.append(Token(value: "\n", range: start..<cursor)) }
                continue
            }
            if character.isLetter || character.isNumber {
                while cursor < text.endIndex {
                    let current = text[cursor]
                    let nextIndex = text.index(after: cursor)
                    let previous = text[text.index(before: cursor)]
                    let next = nextIndex < text.endIndex ? text[nextIndex] : nil
                    let wordJoin = ["'", "’", "-"].contains(current) && previous.isLetter && next?.isLetter == true
                    let numericJoin = [".", ",", ":", "/", "-"].contains(current) && previous.isNumber && next?.isNumber == true
                    let dottedWord = current == "." && previous.isLetter && next?.isLetter == true
                    guard current.isLetter || current.isNumber || wordJoin || numericJoin || dottedWord else { break }
                    cursor = nextIndex
                }
                if cursor < text.endIndex, text[cursor] == "." {
                    let word = String(text[start..<cursor])
                    let letters = word.filter(\.isLetter)
                    let initials = word.contains(".") && !letters.isEmpty && letters.allSatisfy(\.isUppercase)
                    if abbreviations.contains(word.lowercased()) || initials { cursor = text.index(after: cursor) }
                }
            }
            let value = text[start..<cursor].lowercased().replacingOccurrences(of: "’", with: "'")
            result.append(Token(value: value, range: start..<cursor))
        }
        return result
    }

    private static func scan(_ text: String) -> [Event] {
        let tokens = tokenize(text)
        var events: [Event] = []
        var index = 0
        var afterDirective = false
        var itemBodyStart: Int?
        var hasListEvidence = false
        var hasListIntroduction = false
        while index < tokens.count {
            let afterComma = index > 0 && tokens[index - 1].value == ","
            let atBoundary = index == 0 || tokens[index - 1].isBoundary || afterDirective || afterComma
            afterDirective = false
            if atBoundary, introducesList(tokens, at: index) { hasListIntroduction = true }
            guard index != itemBodyStart || (index > 0 && tokens[index - 1].isBoundary) else { index += 1; continue }
            if atBoundary, let match = directive(tokens, at: index) {
                events.append(Event(range: tokens[index].range.lowerBound..<tokens[match.end - 1].range.upperBound,
                                    action: match.action, evidence: match.evidence))
                index = match.end
                afterDirective = true
                itemBodyStart = nil
                if case .end = match.action {
                    hasListEvidence = false
                    hasListIntroduction = false
                } else {
                    hasListEvidence = true
                    hasListIntroduction = true
                }
            } else if var match = marker(tokens, at: index) {
                // "One is ... Three is ..." needs an announced list, not just
                // an old continuation. Keep ordinary "this one is ..." prose.
                if match.evidence == .copularSeries,
                   !hasListIntroduction || (index > 0 && ["this", "that", "the", "each", "every", "only", "which"].contains(tokens[index - 1].value)) {
                    index += 1
                    continue
                }
                if match.evidence == .numeric, !hasListEvidence,
                   index > 0, tokens[index - 1].value != "\n" {
                    // A number after prose ("The answer is: 24. That is
                    // final.") needs repeated item evidence, not just a stop.
                    match = Match(end: match.end, action: match.action, evidence: .unanchoredSeries)
                }
                if !atBoundary && match.evidence != .copularSeries {
                    // Whisper sometimes omits every separator between items:
                    // "5, Apples 6, Bananas". Interior comma markers are only
                    // candidates; a complete anchored series must validate them.
                    guard case .item(.number) = match.action,
                          Int(tokens[index].value) != nil,
                          index + 1 < tokens.count, tokens[index + 1].value == "," else {
                        index += 1
                        continue
                    }
                    match = Match(end: match.end, action: match.action, evidence: .inlineSeries)
                }
                // Commas are also common ASR item separators, but a sequence of
                // bare numbers ("one, two, three") is content, not three items.
                if afterComma && match.evidence != .copularSeries {
                    let previousWasNumber = index >= 2 && number(tokens, at: index - 2)?.end == index - 1
                    if (!hasListEvidence && match.evidence != .explicit) || (previousWasNumber && match.evidence != .explicit) {
                        index += 1
                        continue
                    }
                }
                events.append(Event(range: tokens[index].range.lowerBound..<tokens[match.end - 1].range.upperBound,
                                    action: match.action, evidence: match.evidence))
                index = match.end
                itemBodyStart = index
                hasListEvidence = hasListEvidence || (match.evidence != .contextOnly && match.evidence != .inlineSeries)
            } else {
                index += 1
            }
        }
        return events
    }

    private static func marker(_ tokens: [Token], at start: Int) -> Match? {
        func has(_ words: [String]) -> Bool {
            start + words.count <= tokens.count && Array(tokens[start..<start + words.count].map(\.value)) == words
        }
        func endAfterSeparator(_ index: Int) -> Int {
            index < tokens.count && [",", ".", ":", ";", ")", "-", "–", "—"].contains(tokens[index].value) ? index + 1 : index
        }
        func phraseMarker(_ end: Int, _ marker: Marker) -> Match {
            let separatedEnd = endAfterSeparator(end)
            let evidence: Evidence = separatedEnd != end || end == tokens.count ? .explicit : .contextOnly
            return Match(end: separatedEnd, action: .item(marker), evidence: evidence)
        }
        for words in [["next", "bullet", "point"], ["next", "bullet"], ["bullet", "point"], ["new", "bullet"]] {
            if has(words) { return phraseMarker(start + words.count, .bullet) }
        }
        for words in [["next", "item"], ["new", "item"]] {
            if has(words) { return phraseMarker(start + words.count, .next) }
        }
        if has(["next"]), start + 1 < tokens.count, [",", ":"].contains(tokens[start + 1].value) {
            return Match(end: start + 2, action: .item(.next), evidence: .contextOnly)
        }
        if ["-", "•", "–"].contains(tokens[start].value), start + 1 < tokens.count,
           tokens[start].range.upperBound < tokens[start + 1].range.lowerBound,
           start == 0 || tokens[start - 1].value == "\n" {
            return Match(end: start + 1, action: .item(.bullet), evidence: .explicit)
        }
        var numberStart = start
        let prefixed = ["number", "item"].contains(tokens[start].value)
        if prefixed {
            numberStart += 1
            if numberStart < tokens.count, tokens[numberStart].value == "number" { numberStart += 1 }
        }
        let parenthesized = tokens[start].value == "("
        if parenthesized { numberStart += 1 }
        guard let parsed = number(tokens, at: numberStart) else { return nil }
        if !parenthesized, parsed.value < 1_000, parsed.end < tokens.count, tokens[parsed.end].value == "is" {
            return Match(end: parsed.end + 1, action: .item(.number(parsed.value)), evidence: .copularSeries)
        }
        if prefixed { return phraseMarker(parsed.end, .number(parsed.value)) }
        let end = endAfterSeparator(parsed.end)
        let separator = parsed.end < tokens.count ? tokens[parsed.end].value : ""
        if parenthesized && separator != ")" { return nil }
        guard prefixed || end != parsed.end else { return nil }
        // Bare years are ordinary content, including when the previous hold
        // happened to leave list continuation active. Explicit "item 2026"
        // still works when that large number really is a list marker.
        guard parsed.value < 1_000 else { return nil }
        let numeric = Int(tokens[numberStart].value) != nil
        let explicit = parenthesized || (numeric && parsed.value < 1_000 && [".", ")", ":"].contains(separator))
        let evidence: Evidence = explicit ? .numeric : .series
        return Match(end: end, action: .item(.number(parsed.value)), evidence: evidence)
    }

    // Announcements establish intent but remain part of the dictated prose.
    private static func introducesList(_ tokens: [Token], at start: Int) -> Bool {
        for prefix in [["i", "have"], ["we", "have"], ["here", "is"], ["here's"], ["this", "is"]] {
            let end = start + prefix.count
            if end <= tokens.count, Array(tokens[start..<end].map(\.value)) == prefix,
               listDescriptor(tokens, at: end) != nil { return true }
        }
        return false
    }

    private static func directive(_ tokens: [Token], at start: Int) -> Match? {
        var index = start
        if ["okay", "ok", "alright", "so", "and", "now"].contains(tokens[index].value) {
            index += 1
            if index < tokens.count, tokens[index].value == "," { index += 1 }
        }
        if index < tokens.count, tokens[index].value == "please" { index += 1 }
        if index < tokens.count, tokens[index].value == "let's" {
            index += 1
        } else if index + 1 < tokens.count, tokens[index].value == "let", ["me", "us"].contains(tokens[index + 1].value) {
            index += 2
        }
        guard index < tokens.count else { return nil }

        func finish(_ end: Int, _ action: Action) -> Match? {
            if end == tokens.count { return Match(end: end, action: action, evidence: .explicit) }
            if [".", ",", ":", ";", "!", "?", "\n"].contains(tokens[end].value) {
                return Match(end: end + 1, action: action, evidence: .explicit)
            }
            return nil
        }

        if ["that's", "that", "this"].contains(tokens[index].value) {
            var endStart = index + 1
            if endStart < tokens.count, tokens[endStart].value == "is" { endStart += 1 }
            if endStart < tokens.count, tokens[endStart].value == "the" { endStart += 1 }
            if endStart < tokens.count, tokens[endStart].value == "end" { index = endStart }
        } else if tokens[index].value == "the", index + 1 < tokens.count, tokens[index + 1].value == "end" {
            index += 1
        }
        if ["end", "finish", "stop"].contains(tokens[index].value) {
            var descriptorStart = index + 1
            if descriptorStart < tokens.count, tokens[descriptorStart].value == "of" { descriptorStart += 1 }
            if let descriptor = listDescriptor(tokens, at: descriptorStart) { return finish(descriptor.end, .end) }
        }
        if ["make", "create", "start", "begin"].contains(tokens[index].value),
           let descriptor = listDescriptor(tokens, at: index + 1) {
            return finish(descriptor.end, .start(descriptor.style))
        }
        if ["continue", "resume"].contains(tokens[index].value),
           let descriptor = listDescriptor(tokens, at: index + 1) {
            return finish(descriptor.end, .resume(descriptor.style))
        }
        if ["numbered", "bulleted", "bullet", "new"].contains(tokens[index].value),
           let descriptor = listDescriptor(tokens, at: index) {
            return finish(descriptor.end, .start(descriptor.style))
        }

        // A bounded word grammar covers "back to the list" and natural returns
        // such as "let me go back to where I was with that list".
        if ["go", "get"].contains(tokens[index].value), index + 1 < tokens.count, tokens[index + 1].value == "back" {
            index += 1
        }
        if tokens[index].value == "back" {
            let allowed: Set<String> = ["to", "where", "i", "was", "with", "on", "the", "that", "this", "my", "our", "previous", "same", "numbered", "bulleted", "bullet", "point"]
            var end = index + 1
            while end < min(tokens.count, index + 16), allowed.contains(tokens[end].value) { end += 1 }
            if end < tokens.count, tokens[end].value == "list" {
                let words = tokens[index...end].map(\.value)
                return finish(end + 1, .resume(styleHint(words)))
            }
        }
        return nil
    }

    private static func listDescriptor(_ tokens: [Token], at start: Int) -> (end: Int, style: SpokenListContext.Style?)? {
        var end = start
        let descriptors: Set<String> = ["a", "an", "the", "that", "this", "my", "our", "new", "previous", "same", "numbered", "ordered", "bulleted", "unordered", "bullet", "point"]
        while end < tokens.count, descriptors.contains(tokens[end].value) { end += 1 }
        guard end < tokens.count else { return nil }
        let words = tokens[start..<end].map(\.value)
        if tokens[end].value == "list" || (tokens[end].value == "points" && words.contains("bullet")) {
            return (end + 1, styleHint(words))
        }
        return nil
    }

    private static func styleHint(_ words: [String]) -> SpokenListContext.Style? {
        if words.contains(where: { ["bullet", "bulleted", "unordered"].contains($0) }) { return .bulleted }
        if words.contains(where: { ["numbered", "ordered"].contains($0) }) { return .numbered }
        return nil
    }

    private static func inferredMarkers(_ events: [Event], in text: String) -> Set<Int> {
        var accepted: Set<Int> = []
        var series: [Int] = []
        func body(_ index: Int) -> String {
            let next = index + 1 < events.count ? events[index + 1].range.lowerBound : text.endIndex
            return String(text[events[index].range.upperBound..<next])
        }
        func finishSeries() {
            defer { series = [] }
            guard series.count >= 2 else { return }
            if series.contains(where: { events[$0].evidence == .inlineSeries }) {
                guard let first = series.first, events[first].evidence != .inlineSeries else { return }
                let numbers = series.compactMap { index -> Int? in
                    if case .item(.number(let number)) = events[index].action { return number }
                    return nil
                }
                guard zip(numbers, numbers.dropFirst()).allSatisfy({ $0 < $1 }) else { return }
                // Counting/range hedges do not supply item bodies. Preserve
                // ambiguous "5, maybe 6, perhaps 7, people" as ordinary speech.
                let hedges: Set<String> = ["and", "or", "maybe", "perhaps", "possibly", "about", "around", "roughly", "approximately"]
                guard series.allSatisfy({ index in
                    let words = contentTokens(body(index))
                    return words.contains(where: { $0.contains(where: \.isLetter) })
                        && words.first.map { !hedges.contains($0) } == true
                }) else { return }
            }
            accepted.formUnion(series)
        }
        for (index, event) in events.enumerated() {
            guard case .item = event.action else { finishSeries(); continue }
            let hasBody = body(index).contains(where: { $0.isLetter || $0.isNumber })
            if case .item(.number) = event.action, event.evidence != .contextOnly, hasBody {
                series.append(index)
            } else { finishSeries() }
        }
        finishSeries()
        return accepted
    }

    private static let smallNumbers = Dictionary(uniqueKeysWithValues:
        ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"].enumerated().map { ($0.element, $0.offset) }
        + ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"].enumerated().map { ($0.element, $0.offset) })
    private static let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
                               "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90]

    private static func number(_ tokens: [Token], at start: Int) -> (value: Int, end: Int)? {
        guard start < tokens.count else { return nil }
        let first = tokens[start].value
        if let value = Int(first), value >= 0 { return (value, start + 1) }
        if ["st", "nd", "rd", "th"].contains(where: first.hasSuffix), let value = Int(first.dropLast(2)), value >= 0 {
            return (value, start + 1)
        }
        var words: [String] = []
        var best: (value: Int, end: Int)?
        for end in start..<min(tokens.count, start + 6) {
            let next = tokens[end].value.split(separator: "-").map(String.init)
            guard !next.isEmpty, next.allSatisfy({ smallNumbers[$0] != nil || tens[$0] != nil || ["hundred", "hundredth", "thousand", "thousandth", "and"].contains($0) }) else { break }
            words += next
            if let value = englishNumber(words) { best = (value, end + 1) }
        }
        return best
    }

    private static func englishNumber(_ words: [String]) -> Int? {
        guard let first = words.first else { return nil }
        if words.count == 1 { return smallNumbers[first] ?? tens[first] }
        if words.count == 2, let tensValue = tens[first], let units = smallNumbers[words[1]], (1...9).contains(units) {
            return tensValue + units
        }
        if let leading = smallNumbers[first], (1...9).contains(leading), ["hundred", "hundredth", "thousand", "thousandth"].contains(words[1]) {
            let multiplier = words[1].hasPrefix("hundred") ? 100 : 1_000
            if words.count == 2 { return leading * multiplier }
            guard !words[1].hasSuffix("th") else { return nil }
            let remainder = Array(words.dropFirst(words[2] == "and" ? 3 : 2))
            if let remainderValue = englishNumber(remainder), remainderValue < multiplier { return leading * multiplier + remainderValue }
        }
        return nil
    }

    private static func itemText(_ content: String) -> String {
        var content = content
        while content.last == "," || content.last == ";" {
            content.removeLast()
            content = content.trimmingCharacters(in: .whitespaces)
        }
        let tokens = tokenize(content)
        // ASR commonly puts sentence stops around short list fragments. Keep
        // punctuation within real multi-sentence items and abbreviations intact.
        if tokens.last?.value == ".", tokens.dropLast().allSatisfy({ ![".", "!", "?"].contains($0.value) }) {
            return String(content.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return content
    }

    private static func contentTokens(_ text: String) -> [String] {
        tokenize(text).map(\.value).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
    }

    private static func containsNonCountingContent(_ text: String) -> Bool {
        let tokens = tokenize(text).filter { $0.value.contains(where: { $0.isLetter || $0.isNumber }) }
        var index = 0
        while index < tokens.count {
            if let number = number(tokens, at: index) { index = number.end }
            else if ["and", "or"].contains(tokens[index].value) { index += 1 }
            else { return true }
        }
        return false
    }

    private static func numberToken(_ number: Int) -> String { "#list-number:\(number)" }

    private static func sourceContentTokens(_ text: String, controls: [Range<String.Index>],
                                            numberMarkers: [(range: Range<String.Index>, number: Int)]) -> [String] {
        var result: [String] = []
        for token in tokenize(text) {
            if controls.contains(where: { $0.contains(token.range.lowerBound) }) { continue }
            if let marker = numberMarkers.first(where: { $0.range.contains(token.range.lowerBound) }) {
                if marker.range.lowerBound == token.range.lowerBound { result.append(numberToken(marker.number)) }
                continue
            }
            if token.value.contains(where: { $0.isLetter || $0.isNumber }) { result.append(token.value) }
        }
        return result
    }

    private static func metaPreludeRanges(in text: String, range: Range<String.Index>) -> [Range<String.Index>] {
        var removed: [Range<String.Index>] = []
        var start = range.lowerBound
        for token in tokenize(text) where range.contains(token.range.lowerBound) && [".", "!", "?", "\n"].contains(token.value) {
            let segment = start..<token.range.upperBound
            if isMeta(String(text[segment])) { removed.append(segment) }
            start = token.range.upperBound
        }
        let remainder = start..<range.upperBound
        if isMeta(String(text[remainder])) { removed.append(remainder) }
        return removed
    }

    private static func removing(_ removed: [Range<String.Index>], from text: String, within range: Range<String.Index>) -> String {
        var kept = ""
        var start = range.lowerBound
        for removal in removed {
            kept += text[start..<removal.lowerBound]
            start = removal.upperBound
        }
        kept += text[start..<range.upperBound]
        return kept
    }

    private static func isMeta(_ text: String) -> Bool {
        let words = tokenize(text).map(\.value).filter { $0.contains(where: \.isLetter) }
        let sentence = words.joined(separator: " ")
        if ["sorry", "go ahead", "hold on", "hang on", "one moment", "wait a second", "just a second", "let me try again", "let's try again", "okay", "ok", "all right"].contains(sentence) { return true }
        let speechTools = ["dictation", "transcription", "voice to text", "voice-to-text", "speech to text", "speech-to-text"]
        let problems: Set<String> = ["ruined", "broken", "wrong", "messed", "stopped", "lost", "failed", "restarting", "restart", "redo", "again"]
        let status = speechTools.compactMap { tool -> String? in
            let prefix = "my \(tool) "
            return sentence.hasPrefix(prefix) ? String(sentence.dropFirst(prefix.count)) : nil
        }.first
        let statusVerbs: Set<String> = ["is", "was", "has", "had", "got", "went", "just", "keeps", "stopped", "failed", "broke"]
        if let status, let first = status.split(separator: " ").first,
           statusVerbs.contains(String(first)), !text.contains("?"), !words.contains("please"), words.contains(where: problems.contains) { return true }
        let screenshot = sentence.contains("screenshot") || sentence.contains("screen shot")
        return screenshot && ["sorry", "i"].contains(words.first ?? "") && words.contains(where: { ["wanted", "wrong", "meant"].contains($0) })
    }
}
