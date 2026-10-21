import AppKit
import Carbon.HIToolbox
import CoreGraphics
import InlayCore
import ScreenCaptureKit

/// Reads unusual words from the focused window when a take starts, so Qwen
/// cleanup can spell names and identifiers that are on screen. The window image
/// and its recognized text stay in this process; only ranked terms reach the server.
@MainActor
final class ScreenContextCapture {
    private var terms: [String]?
    private var waiters: [CheckedContinuation<[String], Never>] = []
    private var task: Task<Void, Never>?

    init(spellingLanguage: String?) {
        task = Task { [weak self] in
            let terms = await Self.read(spellingLanguage: spellingLanguage)
            self?.resolve(terms)
        }
    }

    /// A capture still running at the deadline contributes no terms rather than
    /// delaying transcription.
    func value(waitingAtMost timeout: Duration) async -> [String] {
        if let terms { return terms }
        Task {
            try? await Task.sleep(for: timeout)
            cancel()
        }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func cancel() {
        task?.cancel()
        resolve([])
    }

    private func resolve(_ value: [String]) {
        guard terms == nil else { return }
        terms = value
        for waiter in waiters { waiter.resume(returning: value) }
        waiters.removeAll()
    }

    /// The spell checker separates ordinary words from names; use the dictation
    /// language, or the Mac's preferred language when the server detects it.
    static func spellingLanguage(for language: String?) -> String? {
        let code = language == nil || language == "auto"
            ? Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? $0 }
            : language
        return code.flatMap { NSSpellChecker.shared.availableLanguages.contains($0) ? $0 : nil }
    }

    private static func read(spellingLanguage: String?) async -> [String] {
        // Secure input means a password field has focus; never capture around it.
        guard CGPreflightScreenCaptureAccess(), !IsSecureEventInputEnabled(),
              let window = await offMain({ focusedWindow() }), !Task.isCancelled,
              let image = await windowImage(window.windowID), !Task.isCancelled,
              // Focus can move into a password field or another window while capturing.
              !IsSecureEventInputEnabled(),
              await offMain({ focusedWindow()?.isSameWindow(as: window) ?? false }), !Task.isCancelled
        else { return [] }
        let recognition = Task.detached(priority: .userInitiated) {
            (try? await ScreenContext.recognizeLines(in: image)) ?? []
        }
        let lines = await withTaskCancellationHandler { await recognition.value } onCancel: { recognition.cancel() }
        guard !Task.isCancelled else { return [] }
        // NSSpellChecker is not documented as thread-safe, so ranking stays on the main
        // actor; the per-word cache bounds it to one check per distinct word.
        let checker = NSSpellChecker.shared
        return ScreenContext.terms(fromLines: lines) { word in
            var count = 0
            return checker.checkSpelling(of: word, startingAt: 0, language: spellingLanguage, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: &count).location == NSNotFound
        }
    }

    private static func offMain<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) async -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// AX handles and the matched window number only; compared off the main actor.
    private struct FocusedWindow: @unchecked Sendable {
        let applicationPID: pid_t
        let window: AXUIElement
        let windowID: CGWindowID

        func isSameWindow(as other: Self) -> Bool {
            applicationPID == other.applicationPID && windowID == other.windowID && CFEqual(window, other.window)
        }
    }

    /// The window holding the system's keyboard focus, read the way insertion reads its
    /// target: the system-wide focused application and element rather than the
    /// frontmost app, so a nonactivating panel that owns focus is the window read.
    /// Panels and floating editors can sit above other layers, so the window is matched
    /// by frame among the focused application's windows. Unresolved focus, or focus in
    /// Inlay itself, gets no screen hints. Runs off the main actor with short timeouts,
    /// so an unresponsive app cannot stall dictation.
    private nonisolated static func focusedWindow() -> FocusedWindow? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var applicationPID: pid_t = 0, elementPID: pid_t = 0
        guard !Task.isCancelled,
              let application = element(kAXFocusedApplicationAttribute, of: system),
              let focused = element(kAXFocusedUIElementAttribute, of: system),
              AXUIElementGetPid(application, &applicationPID) == .success, applicationPID > 0,
              AXUIElementGetPid(focused, &elementPID) == .success, elementPID > 0,
              applicationPID != ownPID, elementPID != ownPID else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        guard let window = element(kAXWindowAttribute, of: focused)
            ?? element(kAXTopLevelUIElementAttribute, of: focused) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.25)
        // Reject a mixed snapshot if focus moved between the root queries.
        guard let frame = frame(of: window), let latest = element(kAXFocusedApplicationAttribute, of: system),
              CFEqual(application, latest),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Fail closed when another same-app window shares the frame: the pairing would be a guess.
        let matches = windows.filter { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == applicationPID
                && ((info[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                    .map { abs($0.minX - frame.minX) < 2 && abs($0.minY - frame.minY) < 2
                        && abs($0.width - frame.width) < 2 && abs($0.height - frame.height) < 2 } ?? false)
        }
        guard matches.count == 1, let windowID = matches[0][kCGWindowNumber as String] as? CGWindowID else { return nil }
        return FocusedWindow(applicationPID: applicationPID, window: window, windowID: windowID)
    }

    private nonisolated static func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Accessibility and window-list frames share top-left global coordinates.
    private nonisolated static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func windowImage(_ windowID: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
