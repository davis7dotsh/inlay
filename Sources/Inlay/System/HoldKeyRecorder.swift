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

    enum Input: Equatable {
        case key(HoldKey, down: Bool)
        case escape
    }

    struct Environment {
        var listen: (@escaping (Input) -> Void) -> HotkeyCancellation
        var delay: (@escaping @MainActor () -> Void) -> HotkeyCancellation

        static var live: Self {
            Self(
                listen: { handler in
                    let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                        // Consume Escape here so cancelling never depends on
                        // which view in the window handles the exit command.
                        if event.type == .keyDown, event.keyCode == escapeKeyCode {
                            handler(.escape)
                            return nil
                        }
                        guard let cgEvent = event.cgEvent, let key = HoldKey(keyCode: event.keyCode) else { return event }
                        // Some keyboards report Fn/Globe as keyDown instead of
                        // flagsChanged; a keyDown for a modifier is always a press.
                        let isDown = event.type == .keyDown || key.isDown(in: cgEvent.flags)
                        handler(.key(key, down: isDown))
                        return event
                    }
                    return HotkeyCancellation { if let monitor { NSEvent.removeMonitor(monitor) } }
                },
                delay: { action in
                    let task = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: HoldKeyRecorder.timeoutNanoseconds) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        action()
                    }
                    return HotkeyCancellation { task.cancel() }
                }
            )
        }
    }

    @Published private(set) var isRecording = false
    /// The captured key. Nil when recording stopped without a usable press.
    var onCapture: ((HoldKey) -> Void)?
    var onTimeout: (() -> Void)?
    var onCancel: (() -> Void)?

    private let environment: Environment
    private var listener: HotkeyCancellation?
    private var timeout: HotkeyCancellation?

    init(environment: Environment = .live) {
        self.environment = environment
    }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        listener = environment.listen { [weak self] in self?.receive($0) }
        timeout = environment.delay { [weak self] in self?.timeOut() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        listener?.cancel()
        listener = nil
        timeout?.cancel()
        timeout = nil
    }

    func receive(_ input: Input) {
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
