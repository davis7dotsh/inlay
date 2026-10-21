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


public struct ListControlSpan: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
}

/// A local, deterministic dictation grammar, not a prose rewrite. The caller owns
/// which field/caret the context belongs to and commits it only after insertion.
