import Foundation

enum DictationActivity: Equatable {
    case idle, starting, recording, transcribing, delivering, success, failed

    var isCapturing: Bool { self == .starting || self == .recording }
    var isBusy: Bool { isCapturing || self == .transcribing || self == .delivering }
}

enum DictationDeliveryStatus: String, Equatable {
    case none, inserted, copied, tested, listUpdated, unconfirmed, failed
}

enum DictationTrigger: Equatable {
    case keyboard, dji(UInt64), test

    enum ButtonAction { case start, finish, ignore }

    static func djiButtonAction(deviceID: UInt64, activity: DictationActivity, current: Self?) -> ButtonAction {
        if activity.isCapturing { return current == .dji(deviceID) ? .finish : .ignore }
        return activity.isBusy ? .ignore : .start
    }
}

enum ModelStatus: Equatable {
    case missing, downloading, verifying, installed, failed
}

enum EngineStatus: Equatable {
    case unloaded, loading, ready, transcribing, failed
}
