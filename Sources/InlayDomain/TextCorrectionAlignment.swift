import Foundation


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

