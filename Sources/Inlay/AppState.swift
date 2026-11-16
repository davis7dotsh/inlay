import Foundation

enum DictationActivity: Equatable {
    case idle, starting, recording, transcribing, delivering, success, failed

    var isCapturing: Bool { self == .starting || self == .recording }
    var isBusy: Bool { isCapturing || self == .transcribing || self == .delivering }
}

enum DictationDeliveryStatus: String, Equatable {
    case none, inserted, copied, tested, listUpdated, unconfirmed, failed
}

enum ModelStatus: Equatable {
    case missing, downloading, verifying, installed, failed
}

/// Readiness observed for the model serving the HUD's current take. A loaded
/// helper can still be slow; never infer a cold start from elapsed time alone.
struct HUDModelState: Equatable {
    enum Stage { case speech, proofreading }
    let generationID: UUID
    let stage: Stage
    let startedAt = Date()
    var ready: Bool?
    var hadColdStart = false

    mutating func observe(ready: Bool) {
        self.ready = ready
        hadColdStart = hadColdStart || !ready
    }

    var symbol: String {
        if ready == false || hadColdStart { return "snowflake" }
        return stage == .speech ? "waveform" : "text.badge.checkmark"
    }
}

