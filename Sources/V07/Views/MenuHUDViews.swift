import V07Core
import SwiftUI

struct V07MenuView: View {
    static let width: CGFloat = 310
    @ObservedObject var controller: V07Controller
    var openWindow: () -> Void
    var quit: () -> Void

    private var idleDictationHint: String {
        let key = controller.shortcut == .fn ? "fn" : controller.shortcut.title
        let verb = controller.activationMode == .doubleTapToggle ? "Double tap" : "Press"
        return "\(verb) \(key) to dictate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                V07Mark(size: 20)
                Text("V07").font(.headline)
                DevBadge()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    StatusDot(color: controller.isServerReady ? V07Palette.success : V07Palette.warning)
                    Text(controller.serverStatusMessage)
                        .font(.caption)
                        .foregroundStyle(V07Palette.muted)
                        .lineLimit(1)
                }
                .frame(width: 112, alignment: .trailing)
                .help(controller.serverStatusMessage)
                .accessibilityIdentifier("server.status")
            }
            .frame(height: 28)

            V07MicrophoneTestButton(controller: controller, identifier: "menu.test",
                idleTitle: idleDictationHint)
            Button { controller.copyLastTranscript() } label: {
                Label("Copy last message", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            }
            .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
            .accessibilityIdentifier("menu.copy-last")

            Button("Open \(V07Build.current.displayName)…", action: openWindow)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit \(V07Build.current.displayName)", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(V07Palette.accentInk)
        .background { V07MenuSurface() }
    }
}

@MainActor
final class DictationHUDPresentation: ObservableObject {
    // A fresh identity restarts the entrance even when a new take interrupts
    // the previous result. Hiding cancels any pending entrance task.
    @Published var id: UUID?
}

extension DictationDeliveryStatus {
    var hudSymbol: String {
        switch self {
        case .none: "mic.slash"
        case .inserted: "checkmark"
        case .copied: "doc.on.clipboard"
        case .tested: "waveform"
        case .listUpdated: "list.number"
        case .unconfirmed: "questionmark"
        case .failed: "exclamationmark"
        case .kept: "tray.and.arrow.down"
        }
    }

    var hudLabel: String {
        switch self {
        case .none: "No speech detected"
        case .inserted: "Pasted at your cursor"
        case .copied: "Copied to clipboard"
        case .tested: "Microphone test complete"
        case .listUpdated: "List updated"
        case .unconfirmed: "Check insertion"
        case .failed: "Dictation failed"
        case .kept: "Saved to history"
        }
    }

    var needsAttention: Bool { self == .failed || self == .unconfirmed }
}

struct DictationHUD: View {
    static let width: CGFloat = V07Build.current.isDevelopment ? 200 : 160
    static let height: CGFloat = 44
    static let noticeHeight: CGFloat = 30
    static let morphDuration = 0.18
    @ObservedObject var controller: V07Controller
    @ObservedObject var presentation: DictationHUDPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entered = false
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            capsule
                .frame(width: Self.width, height: Self.height)
            RecordingLimitNote(feedback: controller.recordingFeedback)
                .frame(width: Self.width, height: Self.noticeHeight)
        }
        .task(id: presentation.id) { await enter() }
        .onChange(of: controller.hudExpanded) { _, value in
            guard presentation.id != nil, entered else { return }
            withAnimation(morphAnimation) { expanded = value }
        }
    }

    private var morphAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: Self.morphDuration, bounce: 0.08)
    }

    private func enter() async {
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            entered = false
            expanded = false
        }
        guard presentation.id != nil else { return }
        if reduceMotion {
            entered = true
            expanded = controller.hudExpanded
            return
        }
        await Task.yield()
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(.easeOut(duration: 0.06)) { entered = true }
        // This only stages the visual; microphone startup never waits for it.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(morphAnimation) { expanded = controller.hudExpanded }
    }

    private var capsule: some View {
        ZStack {
            expandedContent
                .frame(width: Self.width, height: Self.height)
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            Button(action: activateCircle) {
                compactIcon
                    .frame(width: Self.height, height: Self.height)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(!expanded)
            .accessibilityHidden(expanded)
            .accessibilityLabel(controller.isBusy ? "Cancel dictation" : hudLabel)
            .accessibilityHint(controller.isBusy ? "Cancel this dictation" : result.needsAttention ? "Open V07 for details" : "Dismiss status")
            .accessibilityIdentifier("hud.circle")
        }
        .frame(width: expanded ? Self.width : Self.height, height: Self.height)
        .clipped()
        .modifier(V07FloatingSurface(cornerRadius: Self.height / 2))
        .overlay(alignment: .topTrailing) {
            if !expanded && V07Build.current.isDevelopment {
                DevBadge().offset(x: 10, y: -6).allowsHitTesting(false)
            }
        }
        .scaleEffect(entered ? 1 : 0.25)
        .opacity(entered ? 1 : 0)
        .onExitCommand {
            if controller.canCancelWithEscape { controller.cancelDictation() }
            else if !controller.isBusy { controller.dismissFeedback() }
        }
        .help(controller.errorMessage ?? hudLabel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(V07Build.current.displayName) dictation")
        .accessibilityValue(controller.errorMessage ?? hudLabel)
        .accessibilityIdentifier("hud.status")
    }

    @ViewBuilder private var expandedContent: some View {
        if let deadline = controller.undoDeadline { undoContent(until: deadline) }
        else { captureContent }
    }

    /// A cancelled take is still saved; this offers a few seconds to paste it.
    private func undoContent(until deadline: Date) -> some View {
        HStack(spacing: 8) {
            Button { controller.undoCancellation() } label: {
                HStack(spacing: 7) {
                    UndoCountdown(deadline: deadline, duration: V07Controller.undoWindow)
                    Text("Undo").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(V07Palette.accentInk)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Paste this dictation after all")
            .accessibilityLabel("Undo cancel")
            .accessibilityHint("Paste this dictation. Otherwise it is only saved to history.")
            .accessibilityIdentifier("hud.undo")
            Button { controller.cancelDictation() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(V07Palette.muted)
            .help("Save to history without pasting")
            .accessibilityLabel("Keep cancelled")
            .accessibilityIdentifier("hud.undo-dismiss")
        }
        .padding(.horizontal, 12)
    }

    private var captureContent: some View {
        HStack(spacing: 10) {
            DevBadge()
            HStack(spacing: 8) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 23)
                    RecordingElapsedTime(feedback: controller.recordingFeedback)
                } else {
                    V07Mark(size: 18)
                    Text("Starting").lineLimit(1)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(V07Palette.muted)
            Button { controller.cancelDictation() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel dictation")
            .accessibilityLabel("Cancel dictation")
            .accessibilityIdentifier("hud.cancel")
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var compactIcon: some View {
        switch controller.activity {
        case .idle, .starting, .recording:
            V07Mark(size: 21)
        case .transcribing, .delivering:
            ProgressView().controlSize(.small)
        case .success, .failed:
            Image(systemName: result.hudSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(result.needsAttention ? V07Palette.warning : V07Palette.accentInk)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
    }

    private var result: DictationDeliveryStatus {
        controller.activity == .failed ? .failed : controller.lastDeliveryStatus
    }

    private var hudLabel: String {
        switch controller.activity {
        case .idle: "Ready"
        case .starting: "Starting microphone"
        case .recording: "Listening"
        case .transcribing: controller.isUndoPending ? "Cancelled. Undo to paste" : "Processing"
        case .delivering: "Inserting"
        case .success, .failed: result.hudLabel
        }
    }

    private func activateCircle() {
        if controller.isBusy { controller.cancelDictation() }
        else {
            if result.needsAttention { controller.onShowWindow?() }
            controller.dismissFeedback()
        }
    }
}

/// Seconds left to undo, drawn as a draining ring around the count.
struct UndoCountdown: View {
    let deadline: Date
    let duration: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let remaining = max(0, deadline.timeIntervalSince(context.date))
            ZStack {
                Circle().stroke(V07Palette.muted.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: remaining / duration)
                    .stroke(V07Palette.accentInk, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 20, height: 20)
        }
        .accessibilityHidden(true)
    }
}

/// Observe only the notice's whole-second changes, independently of the meter.
struct RecordingLimitNote: View {
    let feedback: RecordingFeedback
    @State private var notice: RecordingLimitNotice?

    var body: some View {
        Text(notice?.text ?? "Recording limit in 0:30")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(V07Palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .opacity(notice == nil ? 0 : 1)
            .accessibilityHidden(notice == nil)
            .accessibilityLabel(notice?.accessibilityLabel ?? "")
            .accessibilityIdentifier("hud.recording-limit")
            .onReceive(feedback.$limitNotice.removeDuplicates()) { notice = $0 }
    }
}
