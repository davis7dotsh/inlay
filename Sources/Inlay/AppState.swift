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

enum EngineStatus: Equatable {
    case unloaded, loading, ready, transcribing, failed
}
