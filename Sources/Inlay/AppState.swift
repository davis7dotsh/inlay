import Foundation

enum DictationActivity: Equatable {
    case idle, starting, recording, transcribing, delivering, success, failed

    var isCapturing: Bool { self == .starting || self == .recording }
    var isBusy: Bool { isCapturing || self == .transcribing || self == .delivering }
}

enum DictationDeliveryStatus: String, Equatable {
    case none, inserted, copied, tested, listUpdated, unconfirmed, failed, kept
}

enum ModelStatus: Equatable {
    case missing, downloading, verifying, installed, failed
}

/// Delivery permission is independent of capture and inference. Only the final
/// synchronous write guard makes it irreversible; cancellation never kills it.
@MainActor
final class TakeDeliveryGate {
    enum State { case deliver, undoPending, historyOnly, dispatching }
    private(set) var state: State = .deliver
    private(set) var requiresOriginalSelection = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hold() -> Bool {
        guard state == .deliver, !requiresOriginalSelection else { return false }
        requiresOriginalSelection = true
        state = .undoPending
        return true
    }

    func decide(insert: Bool) {
        guard state == .undoPending else { return }
        state = insert ? .deliver : .historyOnly
        waiter?.resume(); waiter = nil
    }

    func keepInHistory() {
        guard state != .dispatching else { return }
        state = .historyOnly
        waiter?.resume(); waiter = nil
    }

    func waitForDecision() async {
        guard state == .undoPending else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func beginDelivery() -> Bool {
        guard state == .deliver else { return state == .dispatching }
        state = .dispatching
        return true
    }
}
