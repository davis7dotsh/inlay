import AppKit

/// Lets the user choose a hold key by pressing it instead of picking from a
/// list. While recording, a local event monitor watches the supported
/// modifiers; Inlay is frontmost, so the pressed key belongs to the user's
/// intent. Only key-down edges capture: a modifier that was already held when
/// recording started selects nothing when it is later released. Escape
/// cancels recording.
private let escapeKeyCode: UInt16 = 53

@MainActor
final class HoldKeyRecorder: ObservableObject {
    /// Recording stops itself after this long without a usable press.
    static let timeoutNanoseconds: UInt64 = 5_000_000_000

    private enum Input {
        case key(HoldKey, down: Bool)
        case escape
    }

    @Published private(set) var isRecording = false
    /// The captured key. Nil when recording stopped without a usable press.
    var onCapture: ((HoldKey) -> Void)?
    var onTimeout: (() -> Void)?
    var onCancel: (() -> Void)?

    private var monitor: Any?
    private var timeout: Task<Void, Never>?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // Consume Escape here so cancelling never depends on which view in
            // the window handles the exit command.
            if event.type == .keyDown, event.keyCode == escapeKeyCode {
                self?.receive(.escape)
                return nil
            }
            guard let cgEvent = event.cgEvent, let key = HoldKey(keyCode: event.keyCode) else { return event }
            // Some keyboards report Fn/Globe as keyDown instead of
            // flagsChanged; a keyDown for a modifier is always a press.
            let isDown = event.type == .keyDown || key.isDown(in: cgEvent.flags)
            self?.receive(.key(key, down: isDown))
            return event
        }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.timeoutNanoseconds) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timeOut()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timeout?.cancel()
        timeout = nil
    }

    private func receive(_ input: Input) {
        guard isRecording else { return }
        switch input {
        case let .key(key, down):
            guard down else { return }
            stop()
            onCapture?(key)
        case .escape:
            stop()
            onCancel?()
        }
    }

    private func timeOut() {
        stop()
        onTimeout?()
    }
}
