import Foundation

public struct DictationContinuation: Codable, Equatable, Sendable {
    public enum Boundary: String, Codable, Equatable, Sendable { case none, line, paragraph }

    public let list: SpokenListContext?
    public let preview: String
    public let boundary: Boundary

    public init(list: SpokenListContext?, preview: String, boundary: Boundary) {
        self.list = list
        self.preview = preview
        self.boundary = boundary
    }
}

public struct ComposedDictation: Equatable, Sendable {
    public let insertion: String
    public let preview: String
    public let continuation: DictationContinuation?
}

/// Joins only text Inlay itself produced. It never reads an editor's document.
public enum DictationComposer {
    public static func compose(_ formatted: FormattedDictation, previous: DictationContinuation? = nil) -> ComposedDictation {
        let body = formatted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty {
            if !formatted.isControlOnly {
                return ComposedDictation(insertion: "", preview: previous?.preview ?? "", continuation: previous)
            }
            if formatted.endedList && formatted.context == nil {
                let preview = previous?.preview ?? ""
                let needsParagraph = !preview.isEmpty || previous?.boundary == .paragraph
                let state = needsParagraph ? DictationContinuation(list: nil, preview: preview, boundary: .paragraph) : nil
                return ComposedDictation(insertion: "", preview: preview, continuation: state)
            }
            let carried = formatted.continuesPreviousList ? previous : nil
            let preview = carried?.preview ?? ""
            let needsParagraph = previous?.boundary == .paragraph || previous?.preview.isEmpty == false
            let boundary: DictationContinuation.Boundary = carried?.boundary ?? (needsParagraph ? .paragraph : .none)
            let state = DictationContinuation(list: formatted.context, preview: preview, boundary: boundary)
            return ComposedDictation(insertion: "", preview: preview, continuation: state)
        }

        let continuing = formatted.continuesPreviousList && previous != nil
        let separator: String
        if let previous {
            if continuing {
                switch previous.boundary {
                case .none: separator = ""
                case .line: separator = "\n"
                case .paragraph: separator = "\n\n"
                }
            } else if previous.boundary == .paragraph || previous.list != nil ||
                        (!previous.preview.isEmpty && (formatted.containsList || formatted.context != nil)) {
                separator = "\n\n"
            } else {
                separator = ""
            }
        } else {
            separator = ""
        }

        let finishingPreviousList = formatted.endedList && previous?.list != nil
        let keepPreview = continuing || ((previous?.boundary == .paragraph || finishingPreviousList) && !formatted.containsList)
        let preview: String
        if keepPreview, let previous, !previous.preview.isEmpty {
            preview = previous.preview + separator + body
        } else {
            preview = body
        }

        let tailIsList = formatted.endsWithList
        // Don't append a space to list items: a later hold supplies its own
        // newline. Paragraph breaks after "end list" are similarly deferred
        // until actual text arrives, never sent as a Return key or empty paste.
        let suffix = tailIsList || formatted.context != nil ? "" : " "
        let boundary: DictationContinuation.Boundary
        if formatted.context != nil { boundary = .line }
        else if tailIsList { boundary = .paragraph }
        else { boundary = .none }
        let continuation = DictationContinuation(list: formatted.context, preview: preview, boundary: boundary)
        return ComposedDictation(insertion: separator + body + suffix, preview: preview, continuation: continuation)
    }

}

/// Short-lived, bounded memory for separate editor/caret positions and the
/// isolated in-app test. Callers commit only after a confirmed insertion.
public struct DictationContinuationMemory<Anchor: Equatable> {
    private struct Entry {
        let anchor: Anchor
        let continuation: DictationContinuation
        let timestamp: TimeInterval
    }

    private var entries: [Entry] = []
    private let lifetime: TimeInterval
    private let capacity: Int

    public init(lifetime: TimeInterval = 15 * 60, capacity: Int = 8) {
        self.lifetime = max(0, lifetime)
        self.capacity = max(1, capacity)
    }

    public mutating func continuation(for anchor: Anchor, now: TimeInterval) -> DictationContinuation? {
        expire(now: now)
        return entries.last(where: { $0.anchor == anchor })?.continuation
    }

    public mutating func remember(_ continuation: DictationContinuation?, for anchor: Anchor, now: TimeInterval) {
        expire(now: now)
        forget(anchor)
        guard let continuation else { return }
        entries.append(Entry(anchor: anchor, continuation: continuation, timestamp: now))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func forget(_ anchor: Anchor) {
        entries.removeAll { $0.anchor == anchor }
    }

    public mutating func removeAll() { entries.removeAll() }

    private mutating func expire(now: TimeInterval) {
        entries.removeAll { now < $0.timestamp || now - $0.timestamp >= lifetime }
    }
}
