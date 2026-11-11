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

