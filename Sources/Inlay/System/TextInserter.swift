import AppKit
import ApplicationServices
import CoreGraphics

struct InsertionTarget: Equatable {
    let applicationName: String
    fileprivate let application: NSRunningApplication
    fileprivate let snapshot: InsertionFieldSnapshot

    var processIdentifier: pid_t { snapshot.focus.applicationPID }
    var selection: NSRange? { snapshot.selection }
    var capturedAt: TimeInterval { snapshot.capturedAt }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isSameField(as: rhs) && lhs.selection == rhs.selection
    }

    func isSameField(as other: Self) -> Bool {
        !application.isTerminated && !other.application.isTerminated &&
        snapshot.focus.isSameField(as: other.snapshot.focus)
    }
}

enum InsertionOutcome: Equatable {
    case inserted
    case copied(reason: String)
    case unconfirmed(clipboardBackup: Bool)
    case failed(reason: String)
}

enum InsertionDestination: Equatable {
    case field(InsertionTarget)
    case clipboard
    case blocked(reason: String)

    var target: InsertionTarget? {
        if case .field(let target) = self { return target }
        return nil
    }
}

/// Immutable AX handles and position metadata only. NSRunningApplication stays
/// on the main actor; no document contents or AppKit views cross this boundary.
fileprivate struct FocusedFieldSnapshot: @unchecked Sendable {
    let applicationPID: pid_t
    let elementPID: pid_t
    let element: AXUIElement

    func isSameField(as other: Self) -> Bool {
        applicationPID == other.applicationPID && elementPID == other.elementPID &&
        CFEqual(element, other.element)
    }
}

fileprivate struct InsertionFieldSnapshot: @unchecked Sendable {
    let focus: FocusedFieldSnapshot
    let selection: NSRange?
    let capturedAt: TimeInterval
    let strategy: TextDeliveryStrategy
    let pasteCommand: NativePasteCommand?

    func withSelection(_ selection: NSRange) -> Self {
        Self(focus: focus, selection: selection, capturedAt: capturedAt,
             strategy: strategy, pasteCommand: pasteCommand)
    }
}

private enum InsertionDestinationSnapshot: Sendable {
    case field(InsertionFieldSnapshot)
    case clipboard
    case blocked(reason: String)
}

private enum FocusedElementRead {
    case found(FocusedFieldSnapshot)
    case absent
    case unverified
}

private struct FocusedApplicationSnapshot: @unchecked Sendable {
    let element: AXUIElement
    let window: AXUIElement?
}

@MainActor
struct InsertionDestinationCapture {
    let task: Task<InsertionDestination, Never>
    let cutoff: InsertionCaptureCutoff

    var value: InsertionDestination { get async { await task.value } }
    func finish() { cutoff.finish() }
    func cancel() { task.cancel() }
}

private enum FieldProbe: Sendable {
    case valid(selection: NSRange?)
    case changed(reason: String)
    case blocked(reason: String)
}

enum InsertionFieldPolicy {
    enum Eligibility: Equatable {
        case editable
        case notEditable
        case protected
        case unverified
    }

    static func eligibility(role: String?, subrole: String?, protectedContent: Bool, enabled: Bool) -> Eligibility {
        guard !protectedContent, subrole != kAXSecureTextFieldSubrole as String else { return .protected }
        guard let role, !role.isEmpty else { return .unverified }
        let textRoles = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
        return enabled && textRoles.contains(role) ? .editable : .notEditable
    }

    static func allows(role: String?, subrole: String?, protectedContent: Bool, enabled: Bool) -> Bool {
        eligibility(role: role, subrole: subrole, protectedContent: protectedContent, enabled: enabled) == .editable
    }
}

enum InsertionCapturePolicy {
    static func permitsInsertion(capturedAt: TimeInterval, releasedAt: TimeInterval) -> Bool {
        capturedAt.isFinite && releasedAt.isFinite && capturedAt >= 0 && capturedAt <= releasedAt
    }
}

enum InsertionCaretPolicy {
    static func matches(_ caret: NSRange, replacing selection: NSRange, with text: String) -> Bool {
        guard selection.location >= 0, selection.location != NSNotFound, selection.length >= 0,
              selection.location <= Int.max - selection.length,
              selection.location <= Int.max - text.utf16.count,
              caret.length == 0 else { return false }
        // AX positions count UTF-16 units, not Characters.
        return caret.location == selection.location + text.utf16.count
    }
}

/// Never reads document text, activates another application, or sends Return.
@MainActor
final class TextInserter {
    private let pasteboard: NSPasteboard
    private(set) var confirmedAnchor: InsertionTarget?

    init(pasteboard: NSPasteboard? = nil) {
        self.pasteboard = pasteboard ?? .general
    }

    static func captureTarget() -> InsertionTarget? {
        captureDestination().target
    }

    /// System-wide AX focus identifies the keyboard recipient, including floating
    /// editors. Per-application focus can describe a stale background responder.
    /// Keep lookup off-main so another app's AX IPC never delays the microphone.
    static func beginDestinationCapture() -> InsertionDestinationCapture {
        // This is a change detector, not the target owner. A nonactivating panel
        // may own AX focus without matching NSWorkspace's active application.
        let initialActivation = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let cutoff = InsertionCaptureCutoff()
        let task = Task<InsertionDestination, Never> { @MainActor in
            let snapshot = await readOffMain { await readPreparedDestinationSnapshot(cutoff: cutoff) }
            guard !Task.isCancelled else {
                return .blocked(reason: "Dictation was cancelled. Nothing was pasted or copied.")
            }
            if case .field = snapshot,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != initialActivation {
                return .blocked(reason: "Focus changed while preparing dictation. Nothing was pasted or copied.")
            }
            return destination(from: snapshot)
        }
        return InsertionDestinationCapture(task: task, cutoff: cutoff)
    }

    static func captureDestination() -> InsertionDestination {
        destination(from: readDestinationSnapshot())
    }

    private static func destination(from snapshot: InsertionDestinationSnapshot) -> InsertionDestination {
        switch snapshot {
        case .clipboard: return .clipboard
        case .blocked(let reason): return .blocked(reason: reason)
        case .field(let field):
            guard let application = NSRunningApplication(processIdentifier: field.focus.applicationPID),
                  !application.isTerminated else { return .clipboard }
            return .field(InsertionTarget(applicationName: application.localizedName ?? "the original app",
                                          application: application, snapshot: field))
        }
    }

    /// Position metadata only. Control-only list commands keep their anchor only
    /// when the system-wide focused field and caret still match.
    static func unchangedAnchor(_ target: InsertionTarget?) -> InsertionTarget? {
        guard let target, target.selection != nil,
              let current = captureTarget(), target == current else { return nil }
        return current
    }

    func deliver(_ text: String, copying clipboardText: String, to destination: InsertionDestination,
                 clipboardUnchangedSince changeCount: Int,
                 waitUntilReady: (() async -> Void)? = nil,
                 isCaptureActive: (() -> Bool)? = nil) async -> InsertionOutcome {
        confirmedAnchor = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "There is no text to deliver.")
        }
        guard !Task.isCancelled else { return .failed(reason: "Dictation was cancelled. Nothing was copied.") }
        switch destination {
        case .field(let target):
            let environment = TextDeliveryEnvironment(
                validate: { await Self.validate(target) },
                modifiersAreHeld: { Self.modifiersAreHeld },
                replaceSelection: { Self.replaceSelection($0, in: target) },
                postPaste: { Self.postPaste(into: target, canDispatch: $0) },
                confirmation: { [weak self] text in
                    guard let self else { return .blocked }
                    return await self.confirm(text, in: target)
                },
                pause: { try await Task.sleep(nanoseconds: $0) },
                waitUntilReady: waitUntilReady,
                isCaptureActive: isCaptureActive
            )
            return await TextDeliveryTransaction(pasteboard: pasteboard, environment: environment)
                .deliver(text, copying: clipboardText, strategy: target.snapshot.strategy,
                         clipboardUnchangedSince: changeCount)
        case .blocked(let reason): return .failed(reason: reason)
        case .clipboard:
            switch DictationClipboard.copy(clipboardText, to: pasteboard, onlyIfUnchangedSince: changeCount) {
            case .success: return .copied(reason: "Copied to clipboard")
            case .failure(let error): return .failed(reason: error.localizedDescription)
            }
        }
    }

    private static func validate(_ target: InsertionTarget) async -> TargetValidation {
        guard !target.application.isTerminated else {
            return .changed(reason: "The original app closed.")
        }
        let expected = target.snapshot
        var probe = await readOffMain { probeField(expected.focus) }
        // Some rich editors briefly omit selection metadata during a render.
        // Retry once, never discard the captured caret requirement.
        if expected.selection != nil, case .valid(selection: nil) = probe, !Task.isCancelled {
            do { try await Task.sleep(nanoseconds: 60_000_000) }
            catch { return .blocked(reason: "Dictation was cancelled.") }
            probe = await readOffMain { probeField(expected.focus) }
        }
        guard !Task.isCancelled else { return .blocked(reason: "Dictation was cancelled.") }
        guard !target.application.isTerminated else { return .changed(reason: "The original app closed.") }
        switch probe {
        case .valid(let selection):
            if let original = expected.selection, selection != original {
                return .changed(reason: "The cursor or selection changed.")
            }
            return .valid
        case .changed(let reason): return .changed(reason: reason)
        case .blocked(let reason): return .blocked(reason: reason)
        }
    }

    private func confirm(_ text: String, in target: InsertionTarget) async -> DeliveryConfirmation {
        guard !target.application.isTerminated else { return .unavailable }
        let expected = target.snapshot
        let probe = await Self.readOffMain { Self.probeField(expected.focus) }
        guard !Task.isCancelled else { return .blocked }
        switch probe {
        case .blocked: return .blocked
        case .changed: return .unavailable
        case .valid(let selection):
            guard let original = expected.selection else { return .unavailable }
            guard let selection else { return .pending }
            if InsertionCaretPolicy.matches(selection, replacing: original, with: text) {
                confirmedAnchor = InsertionTarget(applicationName: target.applicationName,
                                                  application: target.application,
                                                  snapshot: expected.withSelection(selection))
                return .confirmed
            }
            return selection == original ? .pending : .unavailable
        }
    }

    private static func replaceSelection(_ text: String, in target: InsertionTarget) -> NativeTextWrite {
        guard !Task.isCancelled, AXIsProcessTrusted(), !target.application.isTerminated else {
            return .uncertain(reason: "Insertion was interrupted.")
        }
        let element = target.snapshot.focus.element
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        switch check {
        case .attributeUnsupported, .notImplemented: return .unsupported
        case .success:
            guard settable.boolValue else { return .unsupported }
        default: return .uncertain(reason: "Native insertion access could not be verified.")
        }
        guard readyToDispatch(into: target) else { return .uncertain(reason: "The original cursor changed.") }
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        switch result {
        case .success: return .acknowledged
        case .attributeUnsupported, .notImplemented: return .unsupported
        default:
            // A timeout may have written text. Verification can resolve it;
            // sending another paste cannot safely resolve an uncertain write.
            return .uncertain(reason: "\(target.applicationName) did not confirm the native write.")
        }
    }

    private static func postPaste(into target: InsertionTarget, canDispatch: () -> Bool) -> PasteDispatch {
        guard !Task.isCancelled, AXIsProcessTrusted(), !target.application.isTerminated else {
            return .blocked(reason: "Insertion was interrupted.")
        }
        if let command = target.snapshot.pasteCommand {
            switch command.invoke(canDispatch: {
                // Menu readiness reads can take time. Check the field first,
                // then the clipboard lease immediately before the action.
                readyToDispatch(into: target) && canDispatch()
            }) {
            case .dispatched: return .sent
            case .blocked: return .blocked(reason: "The app's Paste command could not be invoked safely.")
            case .unavailable: break
            }
        }
        // Only a definitely unattempted/unsupported menu action can fall back.
        // Never send a second route after a successful or timed-out AX action.
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .unavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard CGPreflightPostEventAccess(), readyToDispatch(into: target), canDispatch() else {
            return .blocked(reason: "Focus, cursor, clipboard, or input access changed before pasting.")
        }
        down.postToPid(target.processIdentifier)
        up.postToPid(target.processIdentifier)
        return .sent
    }

    private static func readyToDispatch(into target: InsertionTarget) -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted(), !target.application.isTerminated,
              case .valid(let selection) = probeField(target.snapshot.focus),
              target.selection == nil || selection == target.selection else { return false }
        // Recheck cheap local guards after the potentially slow AX queries.
        return !Task.isCancelled && AXIsProcessTrusted() && !target.application.isTerminated && !modifiersAreHeld
    }

    private static var modifiersAreHeld: Bool {
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return !CGEventSource.flagsState(.hidSystemState).intersection(modifiers).isEmpty
    }

    private static func readOffMain<Value: Sendable>(_ operation: @escaping @Sendable () async -> Value) async -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func probeField(_ expected: FocusedFieldSnapshot) -> FieldProbe {
        guard !Task.isCancelled, AXIsProcessTrusted() else {
            return .blocked(reason: "Accessibility access is unavailable or dictation was cancelled.")
        }
        let focused: FocusedFieldSnapshot
        switch readFocusedElement() {
        case .found(let value): focused = value
        case .absent: return .changed(reason: "No text field is focused.")
        case .unverified: return .blocked(reason: "The focused field could not be verified.")
        }
        switch fieldEligibility(of: focused.element) {
        case .editable: break
        case .protected: return .blocked(reason: "This field is protected.")
        case .notEditable: return .changed(reason: "The field is no longer editable.")
        case .unverified, nil: return .blocked(reason: "The field's safety could not be verified.")
        }
        guard focused.isSameField(as: expected) else { return .changed(reason: "Focus changed.") }
        // Validate global ownership again after the potentially slow metadata IPC.
        let latest: FocusedFieldSnapshot
        switch readFocusedElement() {
        case .found(let value): latest = value
        case .absent: return .changed(reason: "No text field is focused.")
        case .unverified: return .blocked(reason: "The focused field could not be verified.")
        }
        guard latest.isSameField(as: expected) else {
            // A newly focused protected/unknown field must not turn into an
            // automatic clipboard copy just because the original field was safe.
            switch fieldEligibility(of: latest.element) {
            case .protected: return .blocked(reason: "This field is protected.")
            case .unverified, nil: return .blocked(reason: "The field's safety could not be verified.")
            default: return .changed(reason: "Focus changed.")
            }
        }
        return .valid(selection: selectedRange(of: latest.element))
    }

    private nonisolated static func readPreparedDestinationSnapshot(cutoff: InsertionCaptureCutoff) async -> InsertionDestinationSnapshot {
        guard !Task.isCancelled, AXIsProcessTrusted() else {
            return .blocked(reason: "Allow Accessibility access to check the destination safely. Nothing was pasted or copied.")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        let appRead = elementAttribute(kAXFocusedApplicationAttribute as CFString, of: system)
        guard let application = appRead.element else {
            // Keep the ordinary paired app/field check: an absent application
            // does not make a present field with unknown ownership safe to copy.
            return appRead.absent ? readDestinationSnapshot() : .blocked(reason: "The focused application could not be checked safely. Nothing was pasted or copied.")
        }
        var applicationPID: pid_t = 0
        guard AXUIElementGetPid(application, &applicationPID) == .success, applicationPID > 0 else {
            return .blocked(reason: "The focused application could not be checked safely. Nothing was pasted or copied.")
        }
        AXUIElementSetMessagingTimeout(application, 0.2)
        let windowRead = checkedAttribute(kAXFocusedWindowAttribute as CFString, of: application)
        let window = windowRead.value.flatMap { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
        let original = FocusedApplicationSnapshot(element: application, window: window)
        let preparation = InsertionPreparationEnvironment<InsertionFieldSnapshot>(
            read: {
                switch readDestinationSnapshot(expectedApplication: original) {
                case .field(let field): return .ready(field, capturedAt: field.capturedAt)
                case .clipboard: return .unavailable
                case .blocked(let reason): return .blocked(reason: reason)
                }
            },
            activate: { enableWebAccessibilityIfNeeded(in: original) },
            canWait: { cutoff.canWait },
            now: { ProcessInfo.processInfo.systemUptime },
            pause: { try await Task.sleep(nanoseconds: $0) }
        )
        switch await InsertionPreparation.capture(using: preparation) {
        case .unavailable: return .clipboard
        case .blocked(let reason): return .blocked(reason: reason)
        case .ready(let field, _):
            guard !Task.isCancelled, AXIsProcessTrusted() else {
                return .blocked(reason: "Accessibility access is unavailable or dictation was cancelled.")
            }
            // Preserve the cursor timestamp while slower delivery metadata is
            // discovered, including when the user has already released the key.
            let strategy = deliveryStrategy(of: field.focus.element)
            let command = NativePasteCommand.find(for: field.focus.applicationPID)
            return .field(InsertionFieldSnapshot(focus: field.focus, selection: field.selection,
                                                capturedAt: field.capturedAt, strategy: strategy, pasteCommand: command))
        }
    }

    private nonisolated static func readDestinationSnapshot(expectedApplication: FocusedApplicationSnapshot? = nil) -> InsertionDestinationSnapshot {
        guard !Task.isCancelled, AXIsProcessTrusted() else {
            return .blocked(reason: "Allow Accessibility access to check the destination safely. Nothing was pasted or copied.")
        }
        let focused: FocusedFieldSnapshot
        switch readFocusedElement(expectedApplication: expectedApplication) {
        case .found(let value): focused = value
        case .absent: return .clipboard
        case .unverified:
            return .blocked(reason: "The focused field could not be checked safely. Nothing was pasted or copied.")
        }
        // Timestamp actual cursor capture, not completion of slower menu/role
        // discovery. A genuinely post-release cursor still must never be used.
        let selection = selectedRange(of: focused.element)
        let capturedAt = ProcessInfo.processInfo.systemUptime
        let eligibility = fieldEligibility(of: focused.element)
        switch eligibility {
        case .editable, .notEditable: break
        case .protected: return .blocked(reason: "This is a protected field. Nothing was pasted or copied.")
        case .unverified, nil:
            return .blocked(reason: "The focused field could not be checked safely. Nothing was pasted or copied.")
        }
        guard !Task.isCancelled, AXIsProcessTrusted() else {
            return .blocked(reason: "Accessibility access is unavailable or dictation was cancelled. Nothing was pasted or copied.")
        }
        if let expectedApplication, !applicationIsFocused(expectedApplication) {
            return .blocked(reason: "Focus changed while preparing dictation. Nothing was pasted or copied.")
        }
        if eligibility == .notEditable { return .clipboard }
        return .field(InsertionFieldSnapshot(focus: focused, selection: selection, capturedAt: capturedAt,
                                            strategy: .keyboardPaste, pasteCommand: nil))
    }

    /// Electron documents this application attribute for third-party assistive
    /// clients. Native unsupported apps keep their ordinary immediate path.
    private nonisolated static func enableWebAccessibilityIfNeeded(in application: FocusedApplicationSnapshot) -> InsertionAccessibilityActivation {
        guard !Task.isCancelled, AXIsProcessTrusted(), applicationIsFocused(application) else {
            return .blocked(reason: "Focus or Accessibility access changed while preparing dictation. Nothing was pasted or copied.")
        }
        let app = application.element
        var current: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(app, "AXManualAccessibility" as CFString, &current)
        guard !Task.isCancelled, AXIsProcessTrusted(), applicationIsFocused(application) else {
            return .blocked(reason: "Focus or Accessibility access changed while preparing dictation. Nothing was pasted or copied.")
        }
        if let activation = InsertionAccessibilityPolicy.afterRead(read, enabled: current as? Bool) {
            return activation
        }
        // Never repeat this write during retries: Electron restarts a two-second
        // debounce on every request, and its mode getter is not tree readiness.
        let write = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard !Task.isCancelled, AXIsProcessTrusted(), applicationIsFocused(application) else {
            return .blocked(reason: "Focus or Accessibility access changed while preparing dictation. Nothing was pasted or copied.")
        }
        return InsertionAccessibilityPolicy.afterWrite(write)
    }

    private nonisolated static func applicationIsFocused(_ expected: FocusedApplicationSnapshot) -> Bool {
        guard !Task.isCancelled else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let current = elementAttribute(kAXFocusedApplicationAttribute as CFString, of: system).element,
              CFEqual(current, expected.element) else { return false }
        if let window = expected.window {
            let currentWindow = elementAttribute(kAXFocusedWindowAttribute as CFString, of: expected.element).element
            guard let currentWindow, CFEqual(window, currentWindow) else { return false }
        }
        return true
    }

    /// This is the system's focused object, not an application's remembered
    /// responder. Keep application and element PIDs distinct for remote web AX.
    private nonisolated static func readFocusedElement(expectedApplication: FocusedApplicationSnapshot? = nil) -> FocusedElementRead {
        guard !Task.isCancelled else { return .unverified }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        let appRead = elementAttribute(kAXFocusedApplicationAttribute as CFString, of: system)
        let fieldRead = elementAttribute(kAXFocusedUIElementAttribute as CFString, of: system)
        // A missing value in one query must not mask an IPC failure in the
        // other. A field without a verified application owner is also unsafe.
        guard appRead.element != nil || appRead.absent,
              fieldRead.element != nil || fieldRead.absent else { return .unverified }
        if let expectedApplication {
            guard let app = appRead.element, CFEqual(app, expectedApplication.element),
                  applicationIsFocused(expectedApplication) else { return .unverified }
        }
        if fieldRead.absent { return .absent }
        guard let app = appRead.element, let element = fieldRead.element else { return .unverified }
        var applicationPID: pid_t = 0
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(app, &applicationPID) == .success, applicationPID > 0,
              AXUIElementGetPid(element, &elementPID) == .success, elementPID > 0 else { return .unverified }
        // Reject a mixed snapshot if focus moved between the two root queries.
        let latestApp = elementAttribute(kAXFocusedApplicationAttribute as CFString, of: system)
        guard let latest = latestApp.element, CFEqual(app, latest) else { return .unverified }
        AXUIElementSetMessagingTimeout(element, 0.2)
        return .found(FocusedFieldSnapshot(applicationPID: applicationPID, elementPID: elementPID, element: element))
    }

    private nonisolated static func elementAttribute(_ attribute: CFString, of element: AXUIElement)
        -> (element: AXUIElement?, absent: Bool) {
        guard !Task.isCancelled else { return (nil, false) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .noValue { return (nil, true) }
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, false) }
        return ((value as! AXUIElement), false)
    }

    private nonisolated static func selectedRange(of element: AXUIElement) -> NSRange? {
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let rangeValue = value as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range), range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private nonisolated static func deliveryStrategy(of element: AXUIElement) -> TextDeliveryStrategy {
        let role = checkedAttribute(kAXRoleAttribute as CFString, of: element).value as? String
        guard role == kAXTextFieldRole as String || role == kAXComboBoxRole as String else { return .keyboardPaste }
        // Plain native search fields work well with AX replacement. Web controls
        // need the editor's ordinary Paste/input path, even if AX says settable.
        var current = element
        for _ in 0..<8 {
            guard !Task.isCancelled else { return .keyboardPaste }
            let parentRead = elementAttribute(kAXParentAttribute as CFString, of: current)
            guard let parent = parentRead.element else { return .keyboardPaste }
            AXUIElementSetMessagingTimeout(parent, 0.05)
            let parentRole = checkedAttribute(kAXRoleAttribute as CFString, of: parent)
            guard parentRole.verified, let name = parentRole.value as? String else { return .keyboardPaste }
            if name == "AXWebArea" { return .keyboardPaste }
            if name == kAXWindowRole as String || name == kAXApplicationRole as String { return .nativeSelection }
            current = parent
        }
        return .keyboardPaste
    }

    private nonisolated static func fieldEligibility(of element: AXUIElement) -> InsertionFieldPolicy.Eligibility? {
        let role = checkedAttribute(kAXRoleAttribute as CFString, of: element)
        let subrole = checkedAttribute(kAXSubroleAttribute as CFString, of: element)
        if subrole.value as? String == kAXSecureTextFieldSubrole as String { return .protected }
        let protected = checkedAttribute("AXProtectedContent" as CFString, of: element)
        if protected.value as? Bool == true { return .protected }
        let enabled = checkedAttribute(kAXEnabledAttribute as CFString, of: element)
        guard role.verified, subrole.verified, protected.verified, enabled.verified,
              role.value == nil || role.value as? String != nil,
              subrole.value == nil || subrole.value as? String != nil,
              protected.value == nil || protected.value as? Bool != nil,
              enabled.value == nil || enabled.value as? Bool != nil else { return nil }
        return InsertionFieldPolicy.eligibility(
            role: role.value as? String, subrole: subrole.value as? String,
            protectedContent: protected.value as? Bool ?? false, enabled: enabled.value as? Bool ?? true
        )
    }

    private nonisolated static func checkedAttribute(_ attribute: CFString, of element: AXUIElement) -> (value: CFTypeRef?, verified: Bool) {
        guard !Task.isCancelled else { return (nil, false) }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if result == .attributeUnsupported || result == .noValue { return (nil, true) }
        return (value, result == .success && value != nil)
    }
}

enum ClipboardCopyError: LocalizedError, Equatable {
    case empty
    case cancelled
    case changed
    case unavailable

    var errorDescription: String? {
        switch self {
        case .empty: "There is no text to copy."
        case .cancelled: "Dictation was cancelled. Nothing was copied."
        case .changed: "You copied something newer. Your clipboard was left unchanged."
        case .unavailable: "The clipboard could not accept the transcript."
        }
    }
}

@MainActor
enum DictationClipboard {
    /// Unlike the temporary paste path, an intentional copy stays available.
    /// Keep it local to this Mac and do not mark it transient or restore it later.
    static func copy(_ text: String, to pasteboard: NSPasteboard,
                     onlyIfUnchangedSince expectedCount: Int? = nil) -> Result<Void, ClipboardCopyError> {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return .failure(.unavailable) }
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard expectedCount.map({ OwnedPasteboardRevisions.onlyOwnedChanges(on: pasteboard, since: $0) }) ?? true else {
            return .failure(.changed)
        }
        let ownedCount = OwnedPasteboardRevisions.prepare(pasteboard)
        guard pasteboard.changeCount == ownedCount else { return .failure(.changed) }
        guard pasteboard.writeObjects([item]) else { return .failure(.unavailable) }
        guard pasteboard.changeCount == ownedCount else { return .failure(.changed) }
        return .success(())
    }
}

/// Revisions this app wrote. Queued takes compare the clipboard with the one
/// at their hold; an earlier take's paste lease or copy is not newer user data.
@MainActor
enum OwnedPasteboardRevisions {
    private static var revisions: [NSPasteboard.Name: Set<Int>] = [:]

    static func prepare(_ pasteboard: NSPasteboard) -> Int {
        let count = pasteboard.prepareForNewContents(with: .currentHostOnly)
        revisions[pasteboard.name, default: []].insert(count)
        return count
    }

    /// Whether every change after `baseline`, through `count`, was this app's own write.
    static func onlyOwnedChanges(on pasteboard: NSPasteboard, since baseline: Int, through count: Int? = nil) -> Bool {
        let count = count ?? pasteboard.changeCount
        guard count > baseline else { return count == baseline }
        let owned = revisions[pasteboard.name] ?? []
        return (baseline + 1 ... count).allSatisfy(owned.contains)
    }
}

enum ClipboardPreservationError: LocalizedError {
    case unavailable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable: "The current clipboard cannot be preserved safely. Copy this transcript manually."
        case .tooLarge: "The current clipboard is too large to preserve safely. Copy this transcript manually."
        }
    }
}

@MainActor
struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> Result<Self, ClipboardPreservationError> {
        let changeCount = pasteboard.changeCount
        var totalBytes = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return .failure(.unavailable) }
                totalBytes += data.count
                guard totalBytes <= 32 * 1_024 * 1_024 else { return .failure(.tooLarge) }
                values[type] = data
            }
            items.append(values)
        }
        guard pasteboard.changeCount == changeCount else { return .failure(.unavailable) }
        return .success(Self(changeCount: changeCount, items: items))
    }

    func restore(on pasteboard: NSPasteboard, onlyIfUnchangedSince expectedCount: Int) {
        // If the user copied something during transcription/insertion, it wins.
        guard pasteboard.changeCount == expectedCount else { return }
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        guard pasteboard.changeCount == expectedCount else { return }
        let restoredCount = OwnedPasteboardRevisions.prepare(pasteboard)
        guard pasteboard.changeCount == restoredCount else { return }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
