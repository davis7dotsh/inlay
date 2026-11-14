import Combine
import Foundation

/// High-frequency feedback is observed only by the waveform and clock leaves,
/// never forwarded through the dashboard's controller.
@MainActor
final class RecordingFeedback: ObservableObject {
    @Published private(set) var levels = Array(repeating: Float(0), count: 9)
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var limitNotice: RecordingLimitNotice?

    func append(_ level: Float) {
        let sample = level.isFinite ? min(1, max(0, level)) : 0
        let next = Array(levels.dropFirst()) + [sample]
        // Old peaks still drain through the history; settled silence is free.
        if next != levels { levels = next }
    }

    func updateElapsed(_ elapsed: TimeInterval, limit: Int) {
        let bounded = elapsed.isFinite ? min(Double(limit), max(0, elapsed)) : 0
        let seconds = Int(bounded)
        if seconds != elapsedSeconds { elapsedSeconds = seconds }
        let remaining = limit - seconds
        let notice: RecordingLimitNotice? = (1...60).contains(remaining) ? .approaching(secondsRemaining: remaining, limit: limit) : nil
        if limitNotice != notice { limitNotice = notice }
    }

    func finish(atLimit: Bool, limit: Int) {
        let notice: RecordingLimitNotice? = atLimit ? .stopped(limit: limit) : nil
        if limitNotice != notice { limitNotice = notice }
    }

    func clearLevels() {
        let silence = Array(repeating: Float(0), count: 9)
        if levels != silence { levels = silence }
    }

    func reset() {
        clearLevels()
        if elapsedSeconds != 0 { elapsedSeconds = 0 }
        if limitNotice != nil { limitNotice = nil }
    }
}

enum RecordingLimitNotice: Equatable {
    case approaching(secondsRemaining: Int, limit: Int)
    case stopped(limit: Int)

    var text: String {
        switch self {
        case .approaching(let seconds, _): "Recording limit in \(inlayDuration(Double(seconds)))"
        case .stopped(let limit): "Stopped at the \(Self.label(for: limit)) limit"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .approaching(_, let limit): "Recording is approaching the \(Self.label(for: limit)) limit"
        case .stopped: text
        }
    }

    private static func label(for seconds: Int) -> String {
        if seconds.isMultiple(of: 3_600) { return "\(seconds / 3_600)-hour" }
        if seconds.isMultiple(of: 60) { return "\(seconds / 60)-minute" }
        return "\(seconds)-second"
    }
}
