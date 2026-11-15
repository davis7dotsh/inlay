import TranscriberCore
import AppKit
import CoreGraphics

/// A key that starts and stops dictation. The three modifiers are presets.
/// Fork: any other key is captured by its virtual key code, so a macro pad
/// key (for example F13) can drive dictation too.
enum HoldKey: Hashable, Identifiable {
    case rightOption
    case rightControl
    case fn
    case key(CGKeyCode)

    static let presets: [HoldKey] = [.rightOption, .rightControl, .fn]
    /// Keys offered in Add key without a press. F13 to F20 are on few keyboards, so a
    /// macro pad can send them without a clash.
    static let pickable: [HoldKey] = presets + [105, 107, 113, 106, 64, 79, 80, 90].map { .key($0) }

    /// The configured key for a virtual key code. Escape stays the cancel
    /// key, and the other modifiers cannot drive dictation.
    init?(keyCode: CGKeyCode) {
        switch keyCode {
        case 61: self = .rightOption
        case 62: self = .rightControl
        case 63: self = .fn
        case _ where TranscriberConfiguration.reservedKeyCodes.contains(keyCode): return nil
        default: self = .key(keyCode)
        }
    }

    /// Parses a token from the configuration file. Only canonical tokens
    /// parse, so "key:61" is not a second spelling of Right Option.
    init?(token: String) {
        if let preset = Self.presets.first(where: { $0.token == token }) {
            self = preset
            return
        }
        guard token.hasPrefix("key:"), let code = CGKeyCode(token.dropFirst(4)),
              let key = HoldKey(keyCode: code), key.token == token else { return nil }
        self = key
    }

    /// The token persisted in the configuration file.
    var token: String {
        switch self {
        case .rightOption: "rightOption"
        case .rightControl: "rightControl"
        case .fn: "fn"
        case .key(let code): "key:\(code)"
        }
    }

    var id: String { token }

    var title: String {
        switch self {
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .fn: "Fn / Globe"
        case .key(let code): Self.keyNames[code] ?? "Key \(code)"
        }
    }

    /// The name used in short hints, where "Fn / Globe" is too long.
    var shortTitle: String { self == .fn ? "fn" : title }

    var symbol: String {
        switch self {
        case .rightOption: "⌥"
        case .rightControl: "⌃"
        case .fn: "fn"
        case .key: title
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
        case .key(let code): code
        }
    }

    /// A dedicated key does nothing else, so a hold starts at once and other
    /// input cannot interrupt it. Right Option and Right Control are also
    /// ordinary modifiers, so their holds wait and chords cancel them.
    var isDedicated: Bool {
        switch self {
        case .rightOption, .rightControl: false
        case .fn, .key: true
        }
    }

    /// Virtual key codes from Carbon's Events.h, which names no F21 to F24.
    private static let keyNames: [CGKeyCode: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]

    func isDown(in flags: CGEventFlags) -> Bool {
        // Device-specific bits from IOKit/hidsystem/IOLLEvent.h. The generic
        // alternate/control bits cannot tell left from right modifiers.
        switch self {
        case .rightOption: flags.rawValue & 0x00000040 != 0
        case .rightControl: flags.rawValue & 0x00002000 != 0
        case .fn: flags.contains(.maskSecondaryFn)
        // A captured key is not a modifier. Its state comes from key events.
        case .key: false
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
        case .fn, .key:
            // macOS sets the Fn flag on function-key events, so a captured
            // F-key carries it on every press.
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

    fileprivate var physicallyDown: Bool {
        isPhysicallyDown(
            in: CGEventSource.flagsState(.hidSystemState),
            keyState: CGEventSource.keyState(.hidSystemState, key: keyCode)
        )
    }
}

extension Array where Element == String {
    /// "fn", "fn or F13", or "Right Option, fn, or F13".
    var orList: String {
        guard count > 2, let last else { return joined(separator: " or ") }
        return dropLast().joined(separator: ", ") + ", or " + last
    }
}

/// How dictation starts and stops. Holding requires a sustained press; double
/// tap latches recording on and a second double tap turns it off; single tap
/// (a Transcriber fork addition) starts recording when the key goes down and
/// stops it when the key next goes down, never waiting for a release. Raw
/// values are the tokens persisted in the configuration file.
enum HotkeyActivationMode: String, CaseIterable, Identifiable {
    case hold
    case doubleTapToggle = "doubleTap"
    case singleTapToggle = "singleTap"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: "Hold to talk"
        case .doubleTapToggle: "Double tap to toggle"
        case .singleTapToggle: "Press to start and stop"
        }
    }

    var dictationPrompt: String {
        switch self {
        case .hold: "Hold to dictate."
        case .doubleTapToggle: "Double tap to dictate."
        case .singleTapToggle: "Press to start and stop."
        }
    }

    /// Tap modes latch a take instead of tracking a physical hold. Double tap
    /// decides on release; single tap acts on the press.
    var isToggle: Bool { self != .hold }
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
                // Fork: otherMouseDown lets a middle click count as a chord too.
                let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
                    .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
                guard let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                    eventsOfInterest: mask, callback: transcriberHotkeyCallback,
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

    /// An accepted hold of a dedicated key (Fn or a captured key) is
    /// push-to-talk, not a modifier chord. Views use this same state to leave
    /// Escape available to the focused app. A tap-toggled take is latched, so
    /// Fn shortcuts during it stay ordinary.
    var isHoldingDedicatedKey: Bool { mode == .hold && key.isDedicated && physicalDown && active }
    /// An accepted hold or a press still inside its acceptance delay.
    var isHoldInProgress: Bool { active || pendingPressID != nil }

    /// Fork: every listed key starts and stops dictation the same way.
    var keys: [HoldKey] = [.rightOption] {
        didSet {
            guard keys != oldValue else { return }
            awaitingObservedRelease = false
            reset(cancelActive: true)
            key = keys.first ?? key
            blockAlreadyHeldKey()
        }
    }

    /// Fork: the listed key of the current or last press. Only this key's
    /// edges and hardware state drive the press. Another listed key takes
    /// over only between presses, so pressing it during a hold is a chord.
    private var key: HoldKey = .rightOption

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
    /// Fork: the current single-tap press started the latched take, so a chord
    /// before its release cancels that take. Cleared on release.
    private var pressStartedTake = false
    /// Fork: the down-edge event types seen for the current physical press;
    /// empty when the hold is known only from a hardware poll. Single tap uses
    /// them to tell a companion edge from a new press whose previous release
    /// was missed.
    private var pressEdges: Set<CGEventType> = []
    /// Fork: when the last single-tap press went down (delivery time).
    private var lastPressAt: TimeInterval?
    /// Fork: listening permissions from the last tap refresh. The 2 s health
    /// check keeps this current, so a press does not query TCC every time.
    private var listeningAccess: HotkeyListeningAccess?

    /// Fork: no key goes up and down again this fast, so a single-tap down
    /// edge inside this interval belongs to the previous press.
    private static let minimumPressInterval: TimeInterval = 0.2

    init(environment: HotkeyMonitorEnvironment = .live) {
        self.environment = environment
    }

    @discardableResult
    func start() -> Bool {
        wantsMonitoring = true
        if healthCheck == nil {
            // Only check tap/permission health while idle, never poll for key
            // presses. A dead tap can recover without foregrounding Transcriber.
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
                    self?.reset(cancelActive: false)
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
        listeningAccess = nil
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
        if !physicalDown, let held = keys.first(where: environment.isKeyDown) { key = held }
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
        if !physicalDown, code != key.keyCode, let listed = keys.first(where: { $0.keyCode == code }) {
            // Fork: between presses, any listed key can make the next press.
            // The duplicate-edge window belongs to the last key only, so a
            // fast press of another key still toggles. A double tap needs two
            // taps of the same key.
            key = listed
            lastPressAt = nil
            lastTapAt = nil
        }
        if type == .flagsChanged || ((type == .keyDown || type == .keyUp) && code == key.keyCode) {
            diagnoseModifier(type: type, code: code, flags: event.flags)
        }
        if isHoldingDedicatedKey {
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
                    beginHold(flags: event.flags, edge: type)
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
                // Fork: a captured key presses only by keyDown.
                let pressesOnKeyDown = key == .fn ? key.isDown(in: event.flags) : key.isDedicated
                if pressesOnKeyDown, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    beginHold(flags: event.flags, edge: type)
                }
            } else if physicalDown {
                blockCurrentHold()
            }
        case .keyUp:
            if key.isDedicated, code == key.keyCode { release() }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // In particular, Option+letter shortcuts during the debounce window
            // remain ordinary shortcuts, not surprise microphone activations.
            // Fork: a middle click is a chord like the other buttons.
            if physicalDown { blockCurrentHold() }
        default:
            break
        }
    }

    private func beginHold(flags: CGEventFlags, edge: CGEventType) {
        let now = environment.now()
        if mode == .singleTapToggle, let lastPressAt, now - lastPressAt < Self.minimumPressInterval {
            // Fork: no key goes up and down again this fast, so this edge is the
            // last press's companion or a duplicate, even after its release.
            // One press toggles at most once: a stop never also starts.
            if physicalDown { pressEdges.insert(edge) }
            return
        }
        if physicalDown {
            guard isRepress(edge) else {
                pressEdges.insert(edge)
                return
            }
            // Fork: this press's previous release was never seen. Close that
            // press here so this one still starts or stops the take.
            onDiagnostic?("Press arrived before the last release was seen; counting it as a new press.")
            release()
        }
        physicalDown = true
        pressEdges = [edge]
        if mode == .singleTapToggle { lastPressAt = now }
        armWatchdog()
        if mode == .singleTapToggle, active {
            // Fork: stopping a latched take is always safe, so another held
            // modifier cannot swallow the stopping press.
            togglePress()
            return
        }
        guard !blockedUntilRelease, !key.hasOtherModifiers(in: flags) else {
            blockCurrentHold()
            return
        }
        if mode == .singleTapToggle {
            // Fork: single tap toggles on the down edge. A held key toggles
            // again only after its release, or after a later press proves
            // that release was missed.
            togglePress()
            return
        }
        if mode.isToggle {
            // A tap's meaning is decided when it ends: two taps inside the
            // window toggle recording, so no hold debounce applies.
            return
        }
        if key.isDedicated {
            // A dedicated key is a push-to-talk edge: start in this event turn.
            // Once accepted, ordinary input cannot interrupt the hold.
            acceptPress()
        } else {
            schedulePress()
        }
    }

    /// Fork: in single-tap mode a down edge while the key is already down
    /// means its release was missed, unless it is the same press's companion.
    /// A press yields at most one non-repeating edge per type (Fn can send a
    /// keyDown and a flagsChanged), so an unseen type is a companion and a
    /// repeated type is a new press. A hold known only from a hardware poll
    /// has no observed edge, so any edge after it is a new press. Edges inside
    /// the minimum press interval never get here.
    private func isRepress(_ edge: CGEventType) -> Bool {
        guard mode == .singleTapToggle else { return false }
        return pressEdges.isEmpty || pressEdges.contains(edge)
    }

    private func forgetPressEdges() {
        pressEdges = []
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
        onDiagnostic?(key.isDedicated ? "Hold accepted immediately." : "Hold accepted after 180 ms.")
        // A hold stays active even if no take starts, so its release still
        // reaches the controller (for example, to finish a shortcut check).
        _ = onPress?()
    }

    private func ensureListeningAccess() -> Bool {
        // Fork: read the cached permissions; only a cache miss queries TCC.
        // The tap checks stay live because they are cheap.
        let access = listeningAccess ?? HotkeyListeningAccess(environment.permissions())
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
        // Fork: a single-tap press that just started the take was a shortcut,
        // so that take is cancelled. A press that stopped a take does nothing.
        let startedByThisPress = pressStartedTake
        pressStartedTake = false
        if active, mode == .hold || startedByThisPress {
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
        pressStartedTake = false
        forgetPressEdges()
        watchdog?.cancel()
        watchdog = nil
        // Fork: single tap already acted on the press; its release does nothing.
        if mode == .singleTapToggle { return }
        if mode.isToggle {
            guard wantsMonitoring, wasDown, !wasBlocked else { return }
            registerToggleTap()
            return
        }
        if active {
            active = false
            onRelease?()
        }
    }

    /// Fork: single tap starts or stops the take on the key's down edge.
    private func togglePress() {
        if active {
            active = false
            onDiagnostic?("Press ended the recording.")
            onRelease?()
            return
        }
        guard ensureListeningAccess() else { return }
        guard onPress?() ?? true else {
            onDiagnostic?("Press ignored: recording did not start.")
            return
        }
        active = true
        pressStartedTake = true
        onDiagnostic?("Press accepted; recording stays on until the next press.")
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
        guard mode.isToggle, active else { return }
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
        let name = names[code] ?? HoldKey(keyCode: code)?.title ?? "Modifier \(code)"
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
        listeningAccess = access
        if access.isGranted, !resetHold, let tap, tap.isValid(), tapAccess == access, tap.isEnabled() {
            reportStatus(true)
            return true
        }
        // A dedicated key starts from its event edge, which can precede HID
        // polling. Recovery must not discard that observed hold and accept a
        // companion as new.
        if key.isDedicated, physicalDown { awaitingObservedRelease = true }
        guard access.isGranted else {
            discardTap()
            reportStatus(false)
            return false
        }
        if let tap, tap.isValid(), tapAccess == access {
            // All recovery paths cancel an in-flight hold and require a fresh
            // release. start() used to re-enable blindly, retaining stale state.
            // A latched take survives: the rebuilt listener can still end it.
            // Fork: in single tap the next down edge ends it, even while a
            // polled hold is blocked (see isRepress). Recovery never infers a
            // stop from a hardware poll, which can misreport a key.
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
        if !awaitingObservedRelease, let held = keys.first(where: environment.isKeyDown) { key = held }
        physicalDown = awaitingObservedRelease || environment.isKeyDown(key)
        blockedUntilRelease = physicalDown
        // Fork: an observed hold awaiting its release keeps its edges, so a
        // late companion is not a new press. A polled hold has none.
        if !awaitingObservedRelease { forgetPressEdges() }
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
        let latched = keepLatch && mode.isToggle && active
        active = latched
        physicalDown = false
        blockedUntilRelease = false
        pressStartedTake = false
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

private let transcriberHotkeyCallback: CGEventTapCallBack = { _, type, event, context in
    guard let context else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
    // This tap's run-loop source is installed exclusively on the main run loop.
    MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
    return Unmanaged.passUnretained(event)
}
