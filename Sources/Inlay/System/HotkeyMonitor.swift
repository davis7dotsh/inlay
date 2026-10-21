import AppKit
import CoreGraphics

enum HoldKey: String, CaseIterable, Identifiable {
    case rightOption
    case rightControl
    case fn
    case leftOption
    case leftControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .fn: "Fn / Globe"
        case .leftOption: "Left Option"
        case .leftControl: "Left Control"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption, .leftOption: "⌥"
        case .rightControl, .leftControl: "⌃"
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
        case .leftOption: 58
        case .leftControl: 59
        }
    }

    func isDown(in flags: CGEventFlags) -> Bool {
        // Device-specific bits from IOKit/hidsystem/IOLLEvent.h. The generic
        // alternate/control bits cannot tell left from right modifiers.
        switch self {
        case .rightOption: flags.rawValue & 0x00000040 != 0
        case .rightControl: flags.rawValue & 0x00002000 != 0
        case .fn: flags.contains(.maskSecondaryFn)
        case .leftOption: flags.rawValue & 0x00000020 != 0
        case .leftControl: flags.rawValue & 0x00000001 != 0
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
        case .leftOption:
            disallowed.remove(.maskAlternate)
            if flags.rawValue & 0x00000040 != 0 { return true } // Right Option.
        case .leftControl:
            disallowed.remove(.maskControl)
            if flags.rawValue & 0x00002000 != 0 { return true } // Right Control.
        }
        return !flags.intersection(disallowed).isEmpty
    }

    /// Non-modifier keys a trigger can be recorded onto (they never type).
    /// Keep in sync with the InlayConfiguration decoder allowlist.
    static let recordableKeyTitles: [CGKeyCode: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    static func customKeyTitle(_ code: CGKeyCode) -> String? { recordableKeyTitles[code] }

    func isPhysicallyDown(in flags: CGEventFlags, keyState: @autoclosure () -> Bool) -> Bool {
        // keyState can report a held modifier as up (observed for Right Option
        // on macOS 27 with the built-in keyboard) while the HID modifier flags
        // still carry its device-specific bit. Trust either signal.
        if isDown(in: flags) { return true }
        return self != .fn && keyState()
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
    case tapToggle = "tapToggle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold to talk"
        case .doubleTapToggle: "Double tap to toggle"
        case .tapToggle: "Tap to start and stop"
        }
    }

    var isLatched: Bool { self != .hold }

    var actionVerb: String {
        switch self {
        case .hold: "hold"
        case .doubleTapToggle: "double tap"
        case .tapToggle: "tap"
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
    var isCustomKeyDown: (CGKeyCode) -> Bool = { CGEventSource.keyState(.hidSystemState, key: $0) }
    var flags: () -> CGEventFlags
    var now: () -> TimeInterval
    var createTap: (HotkeyMonitor) -> HotkeyEventTap?
    var delayPress: (@escaping @MainActor () -> Void) -> HotkeyCancellation
    var repeatingTimer: (TimeInterval, @escaping @MainActor () -> Void) -> HotkeyCancellation
    /// Drops a custom trigger's own key events so the focused app does not also act on them.
    var swallowKey: (CGKeyCode) -> HotkeyCancellation? = { _ in nil }

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
            },
            swallowKey: CustomKeySwallower.start
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

/// Passive keyboard monitoring: only a custom trigger key's own events are
/// swallowed (see CustomKeySwallower); nothing is rewritten. An explicit
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
    var isHoldingFn: Bool { mode == .hold && key == .fn && customKeyCode == nil && physicalDown && active }
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

    var customKeyCode: CGKeyCode? {
        didSet {
            guard customKeyCode != oldValue else { return }
            awaitingObservedRelease = false
            reset(cancelActive: true)
            blockAlreadyHeldKey()
            updateKeySwallower()
        }
    }
    var isUsingCustomKey: Bool { customKeyCode != nil }
    /// Command, Option, Control, or Shift make a custom key an app shortcut. Fn may
    /// be needed to produce the function key itself, so it stays allowed.
    nonisolated static let customKeyChordFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
    /// Modifier key codes (Command through Fn). Some keyboards emit a companion
    /// keyDown for a modifier after its flagsChanged; that is not another key.
    nonisolated static let modifierKeyCodes: Set<CGKeyCode> = Set(54...63)

    private let environment: HotkeyMonitorEnvironment
    private var tap: HotkeyEventTap?
    private var tapAccess: HotkeyListeningAccess?
    private var keySwallower: (code: CGKeyCode, lifetime: HotkeyCancellation)?
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
        let wasDown = physicalDown || activeKeyIsDown()
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
        if customKeyCode == nil,
           type == .flagsChanged || ((type == .keyDown || type == .keyUp) && code == key.keyCode) {
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
            // The controller honors this only while capturing; Escape during
            // processing belongs to the focused app.
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
            if customKeyCode != nil {
                // A modifier during the debounce makes this press a chord. Once a
                // hold is accepted, a modifier is ordinary input and keeps the take.
                if physicalDown, !holdAccepted, !event.flags.intersection(Self.customKeyChordFlags).isEmpty {
                    blockCurrentHold()
                }
            } else if code == key.keyCode {
                if key.isDown(in: event.flags) {
                    beginHold(flags: event.flags)
                } else {
                    release()
                }
            } else if physicalDown, key.hasOtherModifiers(in: event.flags) {
                blockCurrentHold()
            }
        case .keyDown:
            if let customKeyCode {
                if code == customKeyCode {
                    if !event.flags.intersection(Self.customKeyChordFlags).isEmpty {
                        // Command+F5 and similar chords stay the focused app's shortcuts;
                        // autorepeat under a modifier added mid-take does not end it.
                        if physicalDown, !holdAccepted { blockCurrentHold() }
                    } else if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { beginCustomHold() }
                } else if physicalDown, !Self.modifierKeyCodes.contains(code) {
                    blockCurrentHold()
                }
            // Some HID keyboards send a companion keyDown for the modifier
            // itself after flagsChanged. That is not an Option+other-key chord.
            } else if code == key.keyCode {
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
            if let customKeyCode, code == customKeyCode { release() }
            else if key == .fn, code == key.keyCode { release() }
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
        if mode.isLatched {
            // A tap's meaning is decided when it ends, so no hold debounce applies.
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

    private func beginCustomHold() {
        guard !physicalDown else { return }
        physicalDown = true
        armWatchdog()
        guard !blockedUntilRelease else {
            blockCurrentHold()
            return
        }
        if mode.isLatched { return }
        schedulePress()
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
        guard activeKeyIsDown() else {
            onDiagnostic?("Hold rejected: hardware key-state query says the key is up.")
            return
        }
        guard isUsingCustomKey || !key.hasOtherModifiers(in: environment.flags()) else {
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

    /// An accepted hold-mode take, as opposed to a pending press or a latch tap.
    private var holdAccepted: Bool { active && mode == .hold }

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
        if mode.isLatched {
            guard wantsMonitoring, wasDown, !wasBlocked else { return }
            if mode == .tapToggle { registerLatchTap() } else { registerToggleTap() }
            return
        }
        if active {
            active = false
            onRelease?()
        }
    }

    private func registerLatchTap() {
        if active {
            active = false
            onDiagnostic?("Tap ended the recording.")
            onRelease?()
            return
        }
        guard ensureListeningAccess() else { return }
        guard onPress?() ?? true else {
            onDiagnostic?("Tap ignored: recording did not start.")
            return
        }
        active = true
        onDiagnostic?("Tap accepted; recording stays on after release.")
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
        guard mode.isLatched, active else { return }
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
        if physicalDown, !activeKeyIsDown() {
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
            updateKeySwallower()
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
                updateKeySwallower()
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
        updateKeySwallower()
        reportStatus(enabled)
        return enabled
    }

    /// Swallowing needs an active tap, which macOS allows only with Accessibility.
    /// Without it, or if the tap cannot be made, the key passes through as before.
    private func updateKeySwallower() {
        let wanted = wantsMonitoring && tap != nil && tapAccess?.accessibility == true ? customKeyCode : nil
        guard keySwallower?.code != wanted else { return }
        keySwallower?.lifetime.cancel()
        keySwallower = wanted.flatMap { code in environment.swallowKey(code).map { (code, $0) } }
    }

    private func activeKeyIsDown() -> Bool {
        if let customKeyCode { return environment.isCustomKeyDown(customKeyCode) }
        return environment.isKeyDown(key)
    }

    private func blockAlreadyHeldKey() {
        physicalDown = awaitingObservedRelease || activeKeyIsDown()
        blockedUntilRelease = physicalDown
        if physicalDown, tap != nil, !awaitingObservedRelease { armWatchdog() }
    }

    private func discardTap(keepLatch: Bool = false) {
        reset(cancelActive: true, keepLatch: keepLatch)
        let previous = tap
        tap = nil
        tapAccess = nil
        updateKeySwallower()
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
        let latched = keepLatch && mode.isLatched && active
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
        keySwallower?.lifetime.cancel()
        tap?.invalidate()
    }
}

/// An active tap on its own thread, so a busy main actor never delays system-wide
/// typing. It is appended after the head-inserted listen-only monitor, which still
/// observes every edge first. A release is dropped when its press was; a tap that
/// stops mid-press (key change, lost access, timeout) can pass an unpaired release.
private final class CustomKeySwallower: @unchecked Sendable {
    private let keyCode: CGKeyCode
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Touched only on the tap thread.
    private var swallowingPress = false
    /// Guards the handoff between the tap thread starting and cancellation.
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var cancelled = false

    private init(keyCode: CGKeyCode) { self.keyCode = keyCode }

    static func start(_ keyCode: CGKeyCode) -> HotkeyCancellation? {
        let swallower = CustomKeySwallower(keyCode: keyCode)
        let retained = Unmanaged.passRetained(swallower)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: inlayKeySwallowCallback, userInfo: retained.toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            retained.release()
            return nil
        }
        swallower.tap = tap
        swallower.source = source
        let thread = Thread {
            swallower.lock.lock()
            guard !swallower.cancelled else {
                swallower.lock.unlock()
                retained.release()
                return
            }
            let runLoop = CFRunLoopGetCurrent()
            swallower.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            swallower.lock.unlock()
            // Returns once cancel stops it or the invalidated source leaves it.
            // Callbacks run only inside this call, so none can follow the release.
            CFRunLoopRun()
            retained.release()
        }
        thread.name = "dev.davis.inlay.custom-key"
        thread.qualityOfService = .userInteractive
        thread.start()
        return HotkeyCancellation { swallower.cancel() }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let runLoop = runLoop
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopSourceInvalidate(source) }
        // The source is already removed, so a loop that has not started yet
        // finds nothing to run; a running one is stopped and woken.
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
    }

    fileprivate func filter(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown || type == .keyUp,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == keyCode else { return false }
        if type == .keyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            swallowingPress = event.flags.intersection(HotkeyMonitor.customKeyChordFlags).isEmpty
        }
        let swallow = swallowingPress
        if type == .keyUp { swallowingPress = false }
        return swallow
    }
}

private let inlayKeySwallowCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let swallower = Unmanaged<CustomKeySwallower>.fromOpaque(context).takeUnretainedValue()
    return swallower.filter(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

private let inlayHotkeyCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // This tap's run-loop source is installed exclusively on the main run loop.
    MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
