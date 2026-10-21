import InlayCore
import SwiftUI

struct InlayMenuView: View {
    static let width: CGFloat = 310
    @ObservedObject var controller: InlayController
    var openWindow: () -> Void
    var quit: () -> Void
    var closeMenu: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                InlayMark(size: 20)
                Text("Inlay").font(.headline)
                DevBadge()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    StatusDot(isReady: controller.isServerReady)
                    if !controller.isServerReady {
                        Text(controller.serverStatusMessage)
                            .font(.caption)
                            .foregroundStyle(InlayPalette.muted)
                            .lineLimit(1)
                    }
                }
                .frame(width: 112, alignment: .trailing)
                .help(controller.serverStatusMessage)
                .accessibilityIdentifier("server.status")
            }
            .frame(height: 28)

            Button {
                if !controller.isCapturing { closeMenu() }
                controller.toggleMenuDictation()
            } label: {
                Label(controller.isCapturing ? "Stop dictation" : "Start dictation",
                      systemImage: controller.isCapturing ? "stop.fill" : "mic")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 26)
            }
            .disabled(!controller.canTest && !controller.isCapturing)
            .help("Dictate at your cursor. Without a placed cursor, the text is copied.")
            .accessibilityLabel(controller.isCapturing ? "Stop dictation" : "Start dictation")
            .accessibilityIdentifier("menu.dictate")

            InlayMicrophoneTestButton(controller: controller, identifier: "menu.test")
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

            Button("Open \(InlayBuild.current.displayName)…", action: openWindow)
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button("Quit \(InlayBuild.current.displayName)", action: quit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(18)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .tint(InlayPalette.accentInk)
        .background { InlayMenuSurface() }
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

    var needsAttention: Bool { self == .copied || self == .failed || self == .unconfirmed }
}

struct DictationHUD: View {
    static let width: CGFloat = 200 + (InlayBuild.current.isDevelopment ? 32 : 0)
    static let height: CGFloat = 44
    static let noticeHeight: CGFloat = 30
    static let morphDuration = 0.18
    @ObservedObject var controller: InlayController
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
            guard presentation.id != nil, !activity.isBusy, !controller.attentionPresented else { return }
            withAnimation(morphAnimation) { expanded = false }
        }
        .onChange(of: controller.attentionPresented) { _, presented in
            guard presentation.id != nil, presented else { return }
            withAnimation(morphAnimation) { expanded = true }
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
            expanded = controller.activity.isBusy || controller.attentionPresented
            return
        }
        await Task.yield()
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(.easeOut(duration: 0.06)) { entered = true }
        // This only stages the visual; microphone startup never waits for it.
        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
        guard !Task.isCancelled, presentation.id != nil else { return }
        withAnimation(morphAnimation) { expanded = controller.activity.isBusy || controller.attentionPresented }
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
            .accessibilityLabel(controller.isBusy ? stageText : hudLabel)
            .accessibilityHint(controller.isBusy ? "" : result.needsAttention ? "Open Inlay for details" : "Dismiss status")
            .accessibilityIdentifier("hud.circle")
        }
        .frame(width: expanded ? Self.width : Self.height, height: Self.height)
        .clipped()
        .modifier(InlayFloatingSurface(cornerRadius: Self.height / 2))
        .overlay(alignment: .topTrailing) {
            if !expanded && InlayBuild.current.isDevelopment {
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
        .accessibilityLabel("\(InlayBuild.current.displayName) dictation")
        .accessibilityValue(controller.errorMessage ?? hudLabel)
        .accessibilityIdentifier("hud.status")
    }

    private var expandedContent: some View {
        HStack(spacing: 10) {
            DevBadge()
            if controller.attentionPresented, !controller.isBusy {
                attentionContent
            } else {
            HStack(spacing: 8) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 23)
                    RecordingElapsedTime(feedback: controller.recordingFeedback)
                } else if controller.activity == .starting {
                    InlayMark(size: 18)
                    Text("Starting").lineLimit(1)
                } else {
                    ProgressView().controlSize(.small)
                    Text(stageText).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(InlayPalette.muted)
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
        }
        .padding(.horizontal, 12)
    }

    private var attentionContent: some View {
        HStack(spacing: 8) {
            Image(systemName: result.hudSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(InlayPalette.warning)
            Text(result.hudLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(InlayPalette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if result != .copied, !controller.lastTranscript.isEmpty {
                Button {
                    controller.copyLastTranscript()
                    if controller.lastDeliveryStatus == .copied { controller.dismissFeedback() }
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy again")
                .accessibilityLabel("Copy again")
                .accessibilityIdentifier("hud.copy-again")
            }
            if result != .copied {
                Button { controller.dismissFeedback() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("hud.dismiss")
            }
        }
    }

    @ViewBuilder private var compactIcon: some View {
        switch controller.activity {
        case .idle, .starting, .recording:
            InlayMark(size: 21)
        case .transcribing, .delivering:
            ProgressView().controlSize(.small)
        case .success, .failed:
            Image(systemName: result.hudSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(result.needsAttention ? InlayPalette.warning : InlayPalette.accentInk)
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
        if controller.isBusy { /* Processing is shown expanded; the ✕ button cancels. */ }
        else {
            if result.needsAttention { controller.onShowWindow?() }
            controller.dismissFeedback()
        }
    }
}

/// Observe only the notice's whole-second changes, independently of the meter.
struct RecordingLimitNote: View {
    let feedback: RecordingFeedback
    @State private var notice: RecordingLimitNotice?

    var body: some View {
        Text(notice?.text ?? "Recording limit in 0:30")
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(InlayPalette.ink)
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
