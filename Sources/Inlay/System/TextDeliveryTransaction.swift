import AppKit

enum TextDeliveryStrategy: Equatable { case nativeSelection, keyboardPaste }

enum TargetValidation: Equatable {
    case valid
    case changed(reason: String)
    case blocked(reason: String)
}

enum NativeTextWrite: Equatable {
    case acknowledged
    case unsupported
    case uncertain(reason: String)
}

enum DeliveryConfirmation: Equatable {
    case confirmed
    case pending
    case unavailable
    case blocked
}

enum PasteDispatch: Equatable {
    case sent
    case unavailable
    case blocked(reason: String)
}

@MainActor
struct TextDeliveryEnvironment {
    var validate: () async -> TargetValidation
    var modifiersAreHeld: () -> Bool
    var replaceSelection: (String) -> NativeTextWrite
    /// Recheck the supplied clipboard/cancellation guard after slow metadata
    /// reads, immediately before dispatch. Sent is not an insertion receipt.
    var postPaste: (_ canDispatch: () -> Bool) -> PasteDispatch
    var confirmation: (String) async -> DeliveryConfirmation
    var pause: (UInt64) async throws -> Void
    var waitUntilReady: (() async -> Void)? = nil
    var isCaptureActive: (() -> Bool)? = nil
}

/// Owns delivery and its temporary clipboard lease, not application discovery.
/// The injected boundary never needs document contents to confirm caret movement.
@MainActor
struct TextDeliveryTransaction {
    let pasteboard: NSPasteboard
    let environment: TextDeliveryEnvironment

    func deliver(_ text: String, copying clipboardText: String, strategy: TextDeliveryStrategy,
                 clipboardUnchangedSince changeCount: Int) async -> InsertionOutcome {
        while true {
            await environment.waitUntilReady?()
            guard !Task.isCancelled else { return .failed(reason: Self.cancelled) }
            if let outcome = await attemptDelivery(text, copying: clipboardText, strategy: strategy,
                                                   clipboardUnchangedSince: changeCount) {
                return outcome
            }
        }
    }

    /// A nil outcome means capture resumed before any text was dispatched.
    /// Returning first releases any temporary clipboard lease before waiting.
    private func attemptDelivery(_ text: String, copying clipboardText: String, strategy: TextDeliveryStrategy,
                                 clipboardUnchangedSince changeCount: Int) async -> InsertionOutcome? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(reason: "There is no text to deliver.")
        }
        let prepared = await prepareForDelivery()
        if shouldDeferForCapture { return nil }
        switch prepared {
        case .valid: break
        case .changed(let reason):
            return copyInstead(clipboardText, expectedCount: changeCount, reason: reason)
        case .blocked(let reason): return .failed(reason: reason)
        }
        guard !Task.isCancelled else { return .failed(reason: Self.cancelled) }
        guard !environment.modifiersAreHeld() else {
            return .failed(reason: "A keyboard shortcut is still held. Your words are ready to copy.")
        }

        if strategy == .nativeSelection {
            switch environment.replaceSelection(text) {
            case .unsupported: break
            case .acknowledged, .uncertain:
                let confirmation = await confirm(text)
                guard !Task.isCancelled, confirmation != .blocked else {
                    return .unconfirmed(clipboardBackup: false)
                }
                if confirmation == .confirmed { return .inserted }
                // An acknowledged or timed-out write can still have taken
                // effect. Never retry it through a different delivery route.
                return .unconfirmed(clipboardBackup: copyNewChunk(clipboardText, expectedCount: changeCount))
            }
        }

        let snapshot: ClipboardSnapshot
        switch ClipboardSnapshot.capture(pasteboard) {
        case .success(let value): snapshot = value
        case .failure(let error): return .failed(reason: error.localizedDescription)
        }
        var clipboard = DeliveryClipboardLease(pasteboard: pasteboard, snapshot: snapshot)
        defer { clipboard.restore() }
        guard clipboard.write(text, transient: true) else {
            return .failed(reason: "The clipboard changed or could not accept the transcript. Your words are ready to copy.")
        }

        let validation = await environment.validate()
        guard !Task.isCancelled else { return .failed(reason: Self.cancelled) }
        if shouldDeferForCapture { return nil }
        switch validation {
        case .valid: break
        case .blocked(let reason): return .failed(reason: reason)
        case .changed(let reason):
            let copied = clipboard.keepBackup(clipboardText, unchangedSince: changeCount)
            return copied ? .copied(reason: "Copied to clipboard") : .failed(reason: reason)
        }
        guard !environment.modifiersAreHeld() else {
            return .failed(reason: "A keyboard shortcut is still held. Your words are ready to copy.")
        }
        guard let stagedChangeCount = clipboard.ownedChangeCount,
              pasteboard.changeCount == stagedChangeCount else {
            return .failed(reason: ClipboardCopyError.changed.localizedDescription)
        }
        guard !Task.isCancelled else { return .failed(reason: Self.cancelled) }
        switch environment.postPaste({
            !Task.isCancelled && !shouldDeferForCapture && pasteboard.changeCount == stagedChangeCount
        }) {
        case .sent: break
        case .blocked(let reason):
            if shouldDeferForCapture { return nil }
            return .failed(reason: reason)
        case .unavailable:
            if shouldDeferForCapture { return nil }
            let copied = clipboard.keepBackup(clipboardText, unchangedSince: changeCount)
            return copied ? .copied(reason: "Copied to clipboard") :
                .failed(reason: "macOS could not send the paste. Your words are ready to copy.")
        }

        let confirmation = await confirm(text)
        guard !Task.isCancelled, confirmation != .blocked else {
            return .unconfirmed(clipboardBackup: false)
        }
        if confirmation == .confirmed { return .inserted }
        return .unconfirmed(clipboardBackup: clipboard.keepBackup(clipboardText, unchangedSince: changeCount))
    }

    private static let cancelled = "Dictation was cancelled. Nothing was copied."

    private var shouldDeferForCapture: Bool {
        environment.waitUntilReady != nil && environment.isCaptureActive?() == true
    }

    private func prepareForDelivery() async -> TargetValidation {
        for attempt in 0...8 {
            guard !Task.isCancelled else { return .blocked(reason: Self.cancelled) }
            let validation = await environment.validate()
            guard !Task.isCancelled else { return .blocked(reason: Self.cancelled) }
            if shouldDeferForCapture { return .valid }
            guard validation == .valid else { return validation }
            if !environment.modifiersAreHeld() { return .valid }
            guard attempt < 8 else { break }
            do { try await environment.pause(50_000_000) }
            catch { return .blocked(reason: Self.cancelled) }
        }
        return .blocked(reason: "A keyboard shortcut is still held. Your words are ready to copy.")
    }

    private func confirm(_ text: String) async -> DeliveryConfirmation {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(700))
        var lastObserved: DeliveryConfirmation = .pending
        for attempt in 0...7 {
            guard !Task.isCancelled else { return .blocked }
            guard attempt == 0 || ContinuousClock.now < deadline else { break }
            lastObserved = await environment.confirmation(text)
            guard !Task.isCancelled else { return .blocked }
            // Editors without caret metadata still need time to consume their
            // queued paste before a newer pre-delivery clipboard is restored.
            guard lastObserved == .pending || lastObserved == .unavailable else { return lastObserved }
            guard attempt < 7, ContinuousClock.now < deadline else { break }
            do { try await environment.pause(100_000_000) }
            catch { return .blocked }
        }
        return lastObserved
    }

    private func copyInstead(_ text: String, expectedCount: Int, reason: String) -> InsertionOutcome {
        guard !Task.isCancelled else { return .failed(reason: Self.cancelled) }
        return copyNewChunk(text, expectedCount: expectedCount) ? .copied(reason: "Copied to clipboard") :
            .failed(reason: reason + " Your words are ready to copy.")
    }

    private func copyNewChunk(_ text: String, expectedCount: Int) -> Bool {
        guard !Task.isCancelled, case .success(let snapshot) = ClipboardSnapshot.capture(pasteboard),
              OwnedPasteboardRevisions.onlyOwnedChanges(on: pasteboard, since: expectedCount,
                                                        through: snapshot.changeCount) else { return false }
        var clipboard = DeliveryClipboardLease(pasteboard: pasteboard, snapshot: snapshot)
        defer { clipboard.restore() }
        guard clipboard.write(text, transient: false), !Task.isCancelled else { return false }
        clipboard.commit()
        return true
    }
}

/// Restoration is permitted only while we own the latest pasteboard revision.
/// A backup commits a different, nontransient payload containing just this hold.
@MainActor
private struct DeliveryClipboardLease {
    let pasteboard: NSPasteboard
    let snapshot: ClipboardSnapshot
    private(set) var ownedChangeCount: Int?

    init(pasteboard: NSPasteboard, snapshot: ClipboardSnapshot) {
        self.pasteboard = pasteboard
        self.snapshot = snapshot
    }

    var ownsClipboard: Bool {
        ownedChangeCount.map { pasteboard.changeCount == $0 } ?? false
    }

    mutating func write(_ text: String, transient: Bool) -> Bool {
        let expectedCount = ownedChangeCount ?? snapshot.changeCount
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !Task.isCancelled,
              pasteboard.changeCount == expectedCount else { return false }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return false }
        if transient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        guard !Task.isCancelled, pasteboard.changeCount == expectedCount else { return false }
        let preparedCount = OwnedPasteboardRevisions.prepare(pasteboard)
        ownedChangeCount = preparedCount
        // writeObjects preserves the revision returned by preparation. Never
        // adopt a later revision: it could belong to another clipboard writer.
        guard pasteboard.changeCount == preparedCount,
              pasteboard.writeObjects([item]) else { return false }
        return pasteboard.changeCount == preparedCount
    }

    mutating func keepBackup(_ text: String, unchangedSince count: Int) -> Bool {
        guard OwnedPasteboardRevisions.onlyOwnedChanges(on: pasteboard, since: count, through: snapshot.changeCount),
              ownsClipboard,
              write(text, transient: false), !Task.isCancelled else { return false }
        commit()
        return true
    }

    mutating func commit() { ownedChangeCount = nil }

    func restore() {
        if let ownedChangeCount { snapshot.restore(on: pasteboard, onlyIfUnchangedSince: ownedChangeCount) }
    }
}
