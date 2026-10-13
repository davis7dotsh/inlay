import AppKit
import CoreGraphics

enum HoldKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightControl
    case fn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .fn: "Fn / Globe"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightControl: "⌃"
        case .fn: "fn"
        }
    }

    var note: String? {
        self == .fn ? "Set ‘Press Globe key to’ to ‘Do Nothing’ in Keyboard settings. Some keyboards do not report Fn to apps." : nil
    }

    var keyCode: CGKeyCode {
        switch self {
        case .rightOption: 61
        case .rightControl: 62
        case .fn: 63
        }
    }

    func isDown(in flags: CGEventFlags) -> Bool {
        // Device-specific bits from IOKit/hidsystem/IOLLEvent.h. The generic
        // alternate/control bits cannot tell left from right modifiers.
        switch self {
        case .rightOption: flags.rawValue & 0x00000040 != 0
        case .rightControl: flags.rawValue & 0x00002000 != 0
        case .fn: flags.contains(.maskSecondaryFn)
        }
    }

    func hasOtherModifiers(in flags: CGEventFlags) -> Bool {
        var disallowed: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        switch self {
        case .rightOption:
            disallowed.remove(.maskAlternate)
            if flags.rawValue & 0x00000020 != 0 { return true } // Left Option.
        case .rightControl:
            disallowed.remove(.maskControl)
            if flags.rawValue & 0x00000001 != 0 { return true } // Left Control.
        case .fn:
            disallowed.remove(.maskSecondaryFn)
        }
        return !flags.intersection(disallowed).isEmpty
    }

    func isPhysicallyDown(in flags: CGEventFlags, keyState: @autoclosure () -> Bool) -> Bool {
        // keyState can report a held modifier as up (observed for Right Option
        // on macOS 27 with the built-in keyboard) while the HID modifier flags
        // still carry its device-specific bit. Trust either signal.
        if isDown(in: flags) { return true }
        return self != .fn && keyState()
    }

    /// The key codes monitored for dictation holds; nil for ordinary keys.
    init?(keyCode: CGKeyCode) {
        switch keyCode {
        case HoldKey.rightOption.keyCode: self = .rightOption
        case HoldKey.rightControl.keyCode: self = .rightControl
        case HoldKey.fn.keyCode: self = .fn
        default: return nil
        }
    }

    fileprivate var physicallyDown: Bool {
        isPhysicallyDown(
            in: CGEventSource.flagsState(.hidSystemState),
            keyState: CGEventSource.keyState(.hidSystemState, key: keyCode)
        )
    }
}

/// How dictation starts and stops. Holding requires a sustained press; double
/// tap latches recording on and a second double tap turns it off. Raw values
/// are the tokens persisted in the configuration file.
enum HotkeyActivationMode: String, CaseIterable, Identifiable {
    case hold
    case doubleTapToggle = "doubleTap"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold to talk"
        case .doubleTapToggle: "Double tap to toggle"
        }
    }
}

/// An idempotent lifetime for a scheduled callback or native event-tap resource.
final class HotkeyCancellation {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func cancel() {
        let action = action
        self.action = nil
        action?()
    }
    func complete() { action = nil }
    deinit { cancel() }
}

struct HotkeyEventTap {
    let isValid: () -> Bool
    let isEnabled: () -> Bool
    let setEnabled: (Bool) -> Void
    let lifetime: HotkeyCancellation

    func invalidate() {
        setEnabled(false)
        lifetime.cancel()
    }
}

/// The only injected boundary: no test needs permission prompts, a real event
/// tap, physical key polling, or real-time delays to exercise this monitor.
struct HotkeyMonitorEnvironment {
    var permissions: () -> PermissionSnapshot
    var isKeyDown: (HoldKey) -> Bool
    var flags: () -> CGEventFlags
    var now: () -> TimeInterval
    var createTap: (HotkeyMonitor) -> HotkeyEventTap?
    var delayPress: (@escaping @MainActor () -> Void) -> HotkeyCancellation
    var repeatingTimer: (TimeInterval, @escaping @MainActor () -> Void) -> HotkeyCancellation

    static var live: Self {
        Self(
            permissions: PermissionSnapshot.capture,
            isKeyDown: { $0.physicallyDown },
            flags: { CGEventSource.flagsState(.hidSystemState) },
            now: { ProcessInfo.processInfo.systemUptime },
            createTap: { monitor in
                let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
                    .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
                guard let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: mask, callback: inlayHotkeyCallback,
                    userInfo: Unmanaged.passUnretained(monitor).toOpaque()
                ) else { return nil }
                guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                    CFMachPortInvalidate(tap)
                    return nil
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                return HotkeyEventTap(
                    isValid: { CFMachPortIsValid(tap) },
                    isEnabled: { CGEvent.tapIsEnabled(tap: tap) },
                    setEnabled: { CGEvent.tapEnable(tap: tap, enable: $0) },
                    lifetime: HotkeyCancellation {
                        CGEvent.tapEnable(tap: tap, enable: false)
                        CFMachPortInvalidate(tap)
                        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                    }
                )
            },
            delayPress: { action in
                let task = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 180_000_000) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    action()
                }
                return HotkeyCancellation { task.cancel() }
            },
            repeatingTimer: { interval, action in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in
                    MainActor.assumeIsolated { action() }
                }
                timer.tolerance = interval * 0.1
                RunLoop.main.add(timer, forMode: .common)
                return HotkeyCancellation { timer.invalidate() }
            }
        )
    }
}

private struct HotkeyListeningAccess: Equatable {
    let accessibility: Bool
    let inputMonitoring: Bool
    var isGranted: Bool { accessibility || inputMonitoring }

    init(_ permissions: PermissionSnapshot) {
        accessibility = permissions.accessibility
        inputMonitoring = permissions.inputMonitoring
    }
}

/// Passive keyboard monitoring: no event is swallowed or rewritten. An explicit
/// shortcut check can inspect modifier events in memory, never typed characters.
@MainActor
final class HotkeyMonitor {
    /// Returns whether the requested take actually started. A double-tap latch
    /// is only committed when the controller confirms the recording began;
    /// otherwise a rejected start would leave a phantom latch.
    var onPress: (() -> Bool)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    /// Tap health, not a claim that a particular key event was delivered.
    var onStatusChange: ((Bool) -> Void)?
    /// Set only during an explicit, bounded shortcut check. No persistent log.
    var onDiagnostic: ((String) -> Void)?

    /// An accepted Fn hold is dedicated push-to-talk, not a modifier chord.
    /// Views use this same state to leave Escape available to the focused app.
    /// A double-tap take is latched, so Fn shortcuts during it stay ordinary.
    var isHoldingFn: Bool { mode == .hold && key == .fn && physicalDown && active }
    /// An accepted hold or a press still inside its acceptance delay.
    var isHoldInProgress: Bool { active || pendingPressID != nil }

    var key: HoldKey = .rightOption {
        didSet {
            guard key != oldValue else { return }
            awaitingObservedRelease = false
            reset(cancelActive: true)
            blockAlreadyHeldKey()
        }
    }

    /// Two taps inside this window toggle recording; a lone tap does nothing.
    static let doubleTapWindow: TimeInterval = 0.45

    var mode: HotkeyActivationMode = .hold {
        didSet {
            guard mode != oldValue else { return }
            reset(cancelActive: true)
        }
    }

    private let environment: HotkeyMonitorEnvironment
    private var tap: HotkeyEventTap?
    private var tapAccess: HotkeyListeningAccess?
    private var watchdog: HotkeyCancellation?
    private var healthCheck: HotkeyCancellation?
    private var sleepObserver: NSObjectProtocol?
    private var pendingPress: HotkeyCancellation?
    private var pendingPressID: UUID?
    private var wantsMonitoring = false
    private var reportedStatus: Bool?
    private var physicalDown = false
    private var active = false
    private var blockedUntilRelease = false
    private var awaitingObservedRelease = false
    private var lastTapAt: TimeInterval?

    init(environment: HotkeyMonitorEnvironment = .live) {
        self.environment = environment
    }

    @discardableResult
    func start() -> Bool {
        wantsMonitoring = true
        if healthCheck == nil {
            // Only check tap/permission health while idle, never poll for key
            // presses. A dead tap can recover without foregrounding Inlay.
            healthCheck = environment.repeatingTimer(2) { [weak self] in
                guard let self, wantsMonitoring else { return }
                _ = refreshTap()
            }
        }
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reset(cancelActive: true)
                    self?.blockAlreadyHeldKey()
                }
            }
        }
        return refreshTap()
    }

    func stop() {
        wantsMonitoring = false
        healthCheck?.cancel()
        healthCheck = nil
        discardTap()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        sleepObserver = nil
        reportStatus(false)
    }

    /// A shortcut check must not turn into recording when the check ends while
    /// a modifier is still held or its debounce is pending.
    func requireFreshHold() {
        let wasDown = physicalDown || environment.isKeyDown(key)
        reset(cancelActive: true)
        awaitingObservedRelease = awaitingObservedRelease || wasDown
        blockAlreadyHeldKey()
    }

    func receive(type: CGEventType, event: CGEvent) {
        guard wantsMonitoring else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recoverDisabledTap()
            return
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .flagsChanged || ((type == .keyDown || type == .keyUp) && code == key.keyCode) {
            diagnoseModifier(type: type, code: code, flags: event.flags)
        }
        if isHoldingFn {
            // Keep the accepted hold alive while navigating, typing, scrolling,
            // or clicking another app. Unrelated input can omit the Fn flag; it
            // is not a release. Only this key's own release edge ends the take.
            // The watchdog and tap/sleep recovery still handle lost key-ups.
            if code == key.keyCode,
               type == .keyUp || (type == .flagsChanged && !key.isDown(in: event.flags)) {
                release()
            }
            return
        }
        if type == .keyDown, code == 53 {
            // The controller decides whether anything is cancellable, including
            // transcription after the hold key has already been released.
            // Escape is a single cancel: it clears a hold or a double-tap latch
            // without also reporting that hold's own cancel. A latch-only
            // cancel must not arm the chord block, or the next tap is swallowed.
            active = false
            if physicalDown { blockCurrentHold() }
            onCancel?()
            return
        }
        switch type {
        case .flagsChanged:
            if code == key.keyCode {
                if key.isDown(in: event.flags) {
                    beginHold(flags: event.flags)
                } else {
                    release()
                }
            } else if physicalDown, key.hasOtherModifiers(in: event.flags) {
                blockCurrentHold()
            }
        case .keyDown:
            // Some HID keyboards send a companion keyDown for the modifier
            // itself after flagsChanged. That is not an Option+other-key chord.
            if code == key.keyCode {
                // Fn can arrive as keyDown first. Its event is authoritative;
                // a hardware-state poll can still describe the previous frame.
                // Flag-less or repeated companion events cannot start a hold.
                if key == .fn, key.isDown(in: event.flags),
                   event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    beginHold(flags: event.flags)
                }
            } else if physicalDown {
                blockCurrentHold()
            }
        case .keyUp:
            if key == .fn, code == key.keyCode { release() }
        case .leftMouseDown, .rightMouseDown:
            // In particular, Option+letter shortcuts during the debounce window
            // remain ordinary shortcuts, not surprise microphone activations.
            if physicalDown { blockCurrentHold() }
        default:
            break
        }
    }

    private func beginHold(flags: CGEventFlags) {
        guard !physicalDown else { return }
        physicalDown = true
        armWatchdog()
        guard !blockedUntilRelease, !key.hasOtherModifiers(in: flags) else {
            blockCurrentHold()
            return
        }
        if mode == .doubleTapToggle {
            // A tap's meaning is decided when it ends: two taps inside the
            // window toggle recording, so no hold debounce applies.
            return
        }
        if key == .fn {
            // Fn is a dedicated push-to-talk edge: start in this event turn.
            // Once accepted, ordinary input cannot interrupt the hold.
            acceptPress()
        } else {
            schedulePress()
        }
    }

    private func schedulePress() {
        pendingPress?.cancel()
        let id = UUID()
        pendingPressID = id
        pendingPress = environment.delayPress { [weak self] in
            self?.completePress(id: id)
        }
    }

    private func completePress(id: UUID) {
        guard pendingPressID == id else { return }
        pendingPress?.complete()
        pendingPress = nil
        pendingPressID = nil
        guard wantsMonitoring, physicalDown, !blockedUntilRelease else {
            onDiagnostic?("Hold rejected: waiting for a fresh press.")
            return
        }
        guard environment.isKeyDown(key) else {
            onDiagnostic?("Hold rejected: hardware key-state query says the key is up.")
            return
        }
        guard !key.hasOtherModifiers(in: environment.flags()) else {
            onDiagnostic?("Hold rejected: another modifier is held.")
            return
        }
        acceptPress()
    }

    private func acceptPress() {
        guard wantsMonitoring, physicalDown, !blockedUntilRelease, !active else { return }
        guard ensureListeningAccess() else { return }
        active = true
        onDiagnostic?(key == .fn ? "Hold accepted immediately." : "Hold accepted after 180 ms.")
        // A hold stays active even if no take starts, so its release still
        // reaches the controller (for example, to finish a shortcut check).
        _ = onPress?()
    }

    private func ensureListeningAccess() -> Bool {
        let access = HotkeyListeningAccess(environment.permissions())
        guard access.isGranted, access == tapAccess, let tap, tap.isValid(), tap.isEnabled() else {
            onDiagnostic?("Hold rejected: shortcut access changed; refreshing listener.")
            _ = refreshTap()
            return false
        }
        return true
    }

    private func blockCurrentHold() {
        onDiagnostic?("Hold interrupted; release the key before trying again.")
        blockedUntilRelease = true
        pendingPress?.cancel()
        pendingPress = nil
        pendingPressID = nil
        // A chord only interrupts a physical hold. A latched double-tap take
        // keeps recording; the blocked press just doesn't count as a tap.
        if active, mode == .hold {
            active = false
            onCancel?()
        }
    }

    private func release() {
        // One physical release can produce several edges (fn keyUp plus a
        // flagsChanged clear, a watchdog recovery, a delayed up event). Only
        // the first edge of a press may register a double-tap.
        let wasDown = physicalDown
        let wasBlocked = blockedUntilRelease
        pendingPress?.cancel()
        pendingPress = nil
        pendingPressID = nil
        physicalDown = false
        blockedUntilRelease = false
        awaitingObservedRelease = false
        watchdog?.cancel()
        watchdog = nil
        if mode == .doubleTapToggle {
            guard wantsMonitoring, wasDown, !wasBlocked else { return }
            registerToggleTap()
            return
        }
        if active {
            active = false
            onRelease?()
        }
    }

    private func registerToggleTap() {
        let now = environment.now()
        guard let previousTap = lastTapAt, now - previousTap <= Self.doubleTapWindow else {
            lastTapAt = now
            onDiagnostic?("Tap ignored: double tap to toggle recording.")
            return
        }
        lastTapAt = nil
        if active {
            active = false
            onDiagnostic?("Double tap ended the recording.")
            onRelease?()
            return
        }
        guard ensureListeningAccess() else { return }
        guard onPress?() ?? true else {
            onDiagnostic?("Double tap ignored: recording did not start.")
            return
        }
        active = true
        onDiagnostic?("Double tap accepted; recording stays on after release.")
    }

    /// A take that failed or was cancelled after starting must not leave a
    /// double-tap latch behind; the next double tap should start a new take.
    func clearLatchedTake() {
        guard mode == .doubleTapToggle, active else { return }
        active = false
    }

    private func checkPhysicalRelease() {
        guard wantsMonitoring, let tap else { return }
        if !tap.isValid() || !tap.isEnabled() {
            recoverDisabledTap()
            return
        }
        // A shortcut check or Fn recovery can require an actual release event.
        // A possibly lagging hardware-state query cannot unlock that latch.
        guard !awaitingObservedRelease else { return }
        if physicalDown, !environment.isKeyDown(key) {
            onDiagnostic?(pendingPressID == nil
                ? "Watchdog: hardware key-state query reports release."
                : "Watchdog: hardware query reports release before the 180 ms hold threshold.")
            // Covers missed flagsChanged events, disconnects, and key-up while
            // a menu or a different run-loop mode was temporarily active.
            release()
        }
    }

    private func armWatchdog() {
        guard watchdog == nil else { return }
        watchdog = environment.repeatingTimer(0.12) { [weak self] in
            self?.checkPhysicalRelease()
        }
    }

    private func diagnoseModifier(type: CGEventType, code: CGKeyCode, flags: CGEventFlags) {
        guard let onDiagnostic else { return }
        let names: [CGKeyCode: String] = [
            54: "Right Command", 55: "Left Command", 56: "Left Shift", 57: "Caps Lock",
            58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option",
            62: "Right Control", 63: "Fn / Globe"
        ]
        let name = names[code] ?? "Modifier \(code)"
        let kind = type == .flagsChanged ? "flags" : (type == .keyDown ? "key-down" : "key-up")
        onDiagnostic("\(name) \(kind): 0x\(String(flags.rawValue, radix: 16))")
        if code == key.keyCode {
            let polledFlags = environment.flags()
            onDiagnostic("Selected key: event=\(key.isDown(in: flags)), hardware=\(environment.isKeyDown(key)), hardware flags=0x\(String(polledFlags.rawValue, radix: 16))")
        }
    }

    private func recoverDisabledTap() {
        guard wantsMonitoring else { return }
        _ = refreshTap(resetHold: true)
    }

    private func refreshTap(resetHold: Bool = false) -> Bool {
        let access = HotkeyListeningAccess(environment.permissions())
        if access.isGranted, !resetHold, let tap, tap.isValid(), tapAccess == access, tap.isEnabled() {
            reportStatus(true)
            return true
        }
        // Fn starts from its event edge, which can precede HID polling. Recovery
        // must not discard that observed hold and accept a companion as new.
        if key == .fn, physicalDown { awaitingObservedRelease = true }
        guard access.isGranted else {
            discardTap()
            reportStatus(false)
            return false
        }
        if let tap, tap.isValid(), tapAccess == access {
            // All recovery paths cancel an in-flight hold and require a fresh
            // release. start() used to re-enable blindly, retaining stale state.
            // A latched take survives: the rebuilt listener can still end it.
            reset(cancelActive: true, keepLatch: true)
            blockAlreadyHeldKey()
            tap.setEnabled(true)
            if tap.isValid(), tap.isEnabled() {
                reportStatus(true)
                return true
            }
        }

        // CGEventTapCreate may strip keyboard events when permission is missing.
        // Re-enabling an old port cannot add them after a grant changes.
        discardTap(keepLatch: true)
        guard let newTap = environment.createTap(self) else {
            reportStatus(false)
            return false
        }
        tap = newTap
        tapAccess = access
        newTap.setEnabled(true)
        blockAlreadyHeldKey()
        let enabled = newTap.isValid() && newTap.isEnabled()
        if !enabled { discardTap() }
        reportStatus(enabled)
        return enabled
    }

    private func blockAlreadyHeldKey() {
        physicalDown = awaitingObservedRelease || environment.isKeyDown(key)
        blockedUntilRelease = physicalDown
        if physicalDown, tap != nil, !awaitingObservedRelease { armWatchdog() }
    }

    private func discardTap(keepLatch: Bool = false) {
        reset(cancelActive: true, keepLatch: keepLatch)
        let previous = tap
        tap = nil
        tapAccess = nil
        previous?.invalidate()
    }

    private func reportStatus(_ enabled: Bool) {
        guard reportedStatus != enabled else { return }
        reportedStatus = enabled
        onStatusChange?(enabled)
    }

    private func reset(cancelActive: Bool, keepLatch: Bool = false) {
        pendingPress?.cancel()
        pendingPress = nil
        pendingPressID = nil
        let wasActive = active
        let latched = keepLatch && mode == .doubleTapToggle && active
        active = latched
        physicalDown = false
        blockedUntilRelease = false
        lastTapAt = nil
        watchdog?.cancel()
        watchdog = nil
        if cancelActive, wasActive, !latched { onCancel?() }
    }

    deinit {
        pendingPress?.cancel()
        watchdog?.cancel()
        healthCheck?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        tap?.invalidate()
    }
}

private let inlayHotkeyCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // This tap's run-loop source is installed exclusively on the main run loop.
    MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
