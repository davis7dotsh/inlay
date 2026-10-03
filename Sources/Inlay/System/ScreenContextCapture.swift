import AppKit
import Carbon.HIToolbox
import CoreGraphics
import InlayCore
import ScreenCaptureKit

/// Reads unusual words from the frontmost window when a take starts, so Whisper
/// can spell names and identifiers that are on screen. The window image and its
/// recognized text stay in this process; only ranked terms reach the server.
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
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let image = await windowImage(of: app.processIdentifier), !Task.isCancelled else { return [] }
        let recognition = Task.detached(priority: .userInitiated) {
            (try? await ScreenContext.recognizeLines(in: image)) ?? []
        }
        let lines = await withTaskCancellationHandler { await recognition.value } onCancel: { recognition.cancel() }
        guard !Task.isCancelled else { return [] }
        let checker = NSSpellChecker.shared
        return ScreenContext.terms(fromLines: lines) { word in
            var count = 0
            return checker.checkSpelling(of: word, startingAt: 0, language: spellingLanguage, wrap: false,
                                         inSpellDocumentWithTag: 0, wordCount: &count).location == NSNotFound
        }
    }

    private static func windowImage(of processID: pid_t) async -> CGImage? {
        // The window list is ordered front to back, so the first normal window is the one in use.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let windowID = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == processID && ($0[kCGWindowLayer as String] as? Int) == 0
              })?[kCGWindowNumber as String] as? CGWindowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
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
