import TranscriberCore
import SwiftUI

struct TranscriberMenuView: View {
    static let width: CGFloat = 310
    @ObservedObject var controller: TranscriberController
    var openWindow: () -> Void
    var quit: () -> Void

    private var idleDictationHint: String {
        let key = controller.shortcuts.map(\.shortTitle).orList
        return switch controller.activationMode {
        case .hold: "Press \(key) to dictate"
        case .doubleTapToggle: "Double tap \(key) to dictate"
        case .singleTapToggle: "Press \(key) to start or stop"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TranscriberMark(size: 20)
                Text("Transcriber").font(.headline)
                DevBadge()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    StatusDot(color: controller.isServerReady ? TranscriberPalette.success : TranscriberPalette.warning)
                    Text(controller.serverStatusMessage)
                        .font(.caption)
                        .foregroundStyle(TranscriberPalette.muted)
                        .lineLimit(1)
                }
                .frame(width: 112, alignment: .trailing)
                .help(controller.serverStatusMessage)
                .accessibilityIdentifier("server.status")
            }
            .frame(height: 28)

            TranscriberMicrophoneTestButton(controller: controller, identifier: "menu.test",
                idleTitle: idleDictationHint)
            ForEach(controller.undeliveredResults, id: \.id) { record in
                Button { controller.copyUndeliveredResult(record) } label: {
                    Label("Copy finished dictation", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 26)
                }
                .accessibilityIdentifier("menu.copy-undelivered")
            }
            Button { controller.copyLastTranscript() } label: {
                Label("Copy last message", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            }
            .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
            .accessibilityIdentifier("menu.copy-last")

            Button("Open \(TranscriberBuild.current.displayName)…", action: openWindow)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit \(TranscriberBuild.current.displayName)", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(TranscriberPalette.accentInk)
        .background { TranscriberMenuSurface() }
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
        }
    }

    var needsAttention: Bool { self == .failed || self == .unconfirmed }
}

struct DictationHUD: View {
    static let width: CGFloat = 200 + (TranscriberBuild.current.isDevelopment ? 32 : 0)
    static let height: CGFloat = 44
    static let noticeHeight: CGFloat = 30
    static let morphDuration = 0.18
    @ObservedObject var controller: TranscriberController
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
        .onChange(of: controller.activity) { _, activity in
            guard presentation.id != nil, !activity.isBusy else { return }
            withAnimation(morphAnimation) { expanded = false }
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
            expanded = controller.activity.isBusy
            return
        }
        await Task.yield()
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(.easeOut(duration: 0.06)) { entered = true }
        // This only stages the visual; microphone startup never waits for it.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(morphAnimation) { expanded = controller.activity.isBusy }
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
            .accessibilityLabel(controller.activity.isBusy ? stageText : hudLabel)
            .accessibilityHint(controller.activity.isBusy ? "" : controller.isBusy ? "Show earlier dictation"
                : result.needsAttention ? "Open Transcriber for details" : "Dismiss status")
            .accessibilityIdentifier("hud.circle")
        }
        .frame(width: expanded ? Self.width : Self.height, height: Self.height)
        .clipped()
        .modifier(TranscriberFloatingSurface(cornerRadius: Self.height / 2))
        .overlay(alignment: .topTrailing) {
            if !expanded && TranscriberBuild.current.isDevelopment {
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
        .accessibilityLabel("\(TranscriberBuild.current.displayName) dictation")
        .accessibilityValue(controller.errorMessage ?? hudLabel)
        .accessibilityIdentifier("hud.status")
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            DevBadge()
            HStack(spacing: 8) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 23)
                    RecordingElapsedTime(feedback: controller.recordingFeedback)
                } else if controller.activity == .starting {
                    TranscriberMark(size: 18)
                    Text("Starting").lineLimit(1)
                } else {
                    ProgressView().controlSize(.small)
                    Text(stageText).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TranscriberPalette.muted)
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
            TranscriberMark(size: 21)
        case .transcribing, .delivering:
            ProgressView().controlSize(.small)
        case .success, .failed:
            Image(systemName: result.hudSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(result.needsAttention ? TranscriberPalette.warning : TranscriberPalette.accentInk)
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
        case .transcribing: "Processing"
        case .delivering: "Inserting"
        case .success, .failed: result.hudLabel
        }
    }

    private var stageText: String {
        let stage = controller.hudProgressText ?? hudLabel
        return controller.pendingDictationCount > 1
            ? "\(stage) · \(controller.pendingDictationCount - 1) more" : stage
    }

    private func activateCircle() {
        // Processing is shown expanded; the ✕ button cancels.
        if controller.activity.isBusy { return }
        // Fork: a settled result over an earlier pending take shows that take.
        if controller.isBusy { controller.cancelDictation() }
        else {
            if result.needsAttention { controller.onShowWindow?() }
            controller.dismissFeedback()
        }
    }
}

/// Read only the notice, so the meter never redraws it.
struct RecordingLimitNote: View {
    let feedback: RecordingFeedback

    var body: some View {
        let notice = feedback.limitNotice
        Text(notice?.text ?? "Recording limit in 0:30")
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(TranscriberPalette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .opacity(notice == nil ? 0 : 1)
            .accessibilityHidden(notice == nil)
            .accessibilityLabel(notice?.accessibilityLabel ?? "")
            .accessibilityIdentifier("hud.recording-limit")
    }
}
