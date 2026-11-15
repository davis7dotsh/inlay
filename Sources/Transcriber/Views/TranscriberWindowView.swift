import TranscriberCore
import SwiftUI

private enum TranscriberPage: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case history = "History"
    case data = "Data"
    case microphone = "Microphone"
    case server = "Server preferences"
    case device = "This Mac"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .dictation: "waveform"
        case .history: "clock.arrow.circlepath"
        case .data: "tray.full"
        case .microphone: "mic"
        case .server: "server.rack"
        case .device: "laptopcomputer"
        }
    }
}

struct TranscriberWindowView: View {
    @ObservedObject var controller: TranscriberController
    @State private var page: TranscriberPage = .dictation

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    TranscriberAppIcon(size: 36)
                    Text("Transcriber").font(.system(size: 27, weight: .regular, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    DevBadge()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)

                List(TranscriberPage.allCases) { destination in
                    Button { page = destination } label: {
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .font(.system(size: 13, weight: page == destination ? .medium : .regular))
                            .foregroundStyle(page == destination ? TranscriberPalette.ink : TranscriberPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 37)
                            .background(page == destination ? TranscriberPalette.tint : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("navigation.\(destination.id)")
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                ServerConnectionStatus(controller: controller, compact: true)
                    .padding(18)
            }
            .background { TranscriberSidebarSurface() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            Group {
                switch page {
                case .dictation:
                    DictationPage(controller: controller, showPreferences: { page = .device }, showHistory: { page = .history })
                case .history: HistoryPage(controller: controller)
                case .data: TranscriptDataPage()
                case .microphone: MicrophonePage(controller: controller)
                case .server: ServerPreferencesPage(controller: controller)
                case .device: DevicePreferencesPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TranscriberPalette.canvas)
            .navigationTitle("\(TranscriberBuild.current.displayName) · \(page.rawValue)")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .tint(TranscriberPalette.accent)
        .onExitCommand {
            if controller.isBusy && controller.canCancelWithEscape { controller.cancelDictation() }
        }
    }
}

struct DevBadge: View {
    var body: some View {
        if TranscriberBuild.current.isDevelopment {
            Text("Dev")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(TranscriberPalette.accentInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(TranscriberPalette.tint, in: Capsule())
                .accessibilityLabel("Development build")
        }
    }
}

struct ServerConnectionStatus: View {
    @ObservedObject var controller: TranscriberController
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: controller.isServerReady ? TranscriberPalette.success : TranscriberPalette.warning)
            Text(controller.serverStatusMessage)
                .font(compact ? .caption : .callout)
                .foregroundStyle(TranscriberPalette.ink)
                .lineLimit(compact ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(controller.preferences.endpoint)
                    .font(.caption)
                    .foregroundStyle(TranscriberPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .trailing)
            }
            if controller.isCheckingServer {
                ProgressView().controlSize(.mini).frame(width: 18)
            }
        }
        .frame(minHeight: compact ? 30 : 22)
        .help(controller.serverStatusMessage)
        .accessibilityIdentifier("server.status")
    }
}

struct DictationPage: View {
    @ObservedObject var controller: TranscriberController
    var showPreferences: () -> Void
    var showHistory: () -> Void

    private var keyCaps: some View {
        ForEach(controller.shortcuts) { key in
            TranscriberHoldKeyCap(key: key, isPressed: controller.isRecording)
        }
    }

    private var dictationPrompt: some View {
        Text(controller.activationMode.dictationPrompt)
            .font(.system(size: 28, weight: .medium))
            .tracking(-0.7)
            .fixedSize()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // Many keys move the prompt below the caps, and the caps wrap.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        HStack(spacing: 10) { keyCaps }
                        dictationPrompt
                        Spacer()
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10, alignment: .leading)],
                                  alignment: .leading, spacing: 10) { keyCaps }
                        dictationPrompt
                    }
                }
                .padding(.top, 8)

                HStack {
                    ServerConnectionStatus(controller: controller)
                    Button("Check connection") { controller.refreshServer() }
                        .disabled(controller.isCheckingServer)
                        .accessibilityIdentifier("dictation.refresh-server")
                }
                .frame(height: 32)

                if !controller.allPermissionsGranted {
                    VStack(spacing: 10) {
                        PermissionRow(title: "Microphone", detail: "Capture your voice while dictating.",
                                      granted: controller.permissions.microphone, action: controller.requestMicrophone)
                        PermissionRow(title: "Accessibility", detail: "Use the dictation key and insert text.",
                                      granted: controller.permissions.accessibility, action: controller.requestAccessibility)
                        HStack { PermissionHelpButton(); Spacer() }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(controller.isBusy ? "Current dictation" : "Last dictation").font(.headline)
                        Spacer()
                        Button { controller.copyLastTranscript() } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .disabled(controller.lastTranscript.isEmpty || controller.isBusy)
                    }
                    .frame(height: 28)
                    Divider()
                    transcript
                        .frame(height: 205)
                        .accessibilityIdentifier("dictation.transcript")
                    Divider()
                    HStack {
                        Text(controller.errorMessage ?? controller.lastDelivery)
                            .foregroundStyle(controller.errorMessage == nil ? TranscriberPalette.muted : TranscriberPalette.warning)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !controller.isBusy, let seconds = controller.lastAudioSeconds {
                            Text("\(seconds, specifier: "%.1f") s audio").monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .frame(height: 34, alignment: .top)
                }

                HStack(spacing: 12) {
                    TranscriberMicrophoneTestButton(controller: controller, identifier: "dictation.test")
                    Button("History", action: showHistory)
                    Button { showPreferences() } label: { Image(systemName: "gearshape") }
                        .help("This Mac preferences")
                        .accessibilityLabel("This Mac preferences")
                }
            }
            .padding(30)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var transcript: some View {
        if controller.isBusy {
            HStack(spacing: 20) {
                if controller.isRecording {
                    RecordingWaveform(feedback: controller.recordingFeedback, height: 34)
                } else {
                    ProgressView().controlSize(.small).frame(width: 51)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.statusMessage).font(.headline)
                    if controller.isRecording {
                        HStack {
                            RecordingElapsedTime(feedback: controller.recordingFeedback)
                            Text(controller.recordingInputName ?? controller.selectedInputName)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .foregroundStyle(TranscriberPalette.muted)
                    }
                }
                Spacer()
                Button { controller.cancelDictation() } label: { Image(systemName: "xmark") }
                    .help("Cancel dictation")
                    .accessibilityLabel("Cancel dictation")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if !controller.undeliveredResults.isEmpty {
                HStack {
                    Text("A dictation finished while \(TranscriberBuild.current.displayName) was closed.")
                        .font(.callout)
                        .foregroundStyle(TranscriberPalette.ink)
                    Spacer()
                    Button("Copy") {
                        if let record = controller.undeliveredResults.first {
                            controller.copyUndeliveredResult(record)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            ScrollView {
                Text(controller.lastTranscript.isEmpty ? "Your next thought will appear here." : controller.lastTranscript)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(controller.lastTranscript.isEmpty ? TranscriberPalette.muted : TranscriberPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }
}

struct TranscriberPageHeading: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.7)
            .foregroundStyle(TranscriberPalette.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TranscriberMicrophoneTestButton: View {
    @ObservedObject var controller: TranscriberController
    var identifier: String
    var idleTitle = "Test microphone"
    private var isHeldKey: Bool { controller.isCapturing && !controller.canCancelWithEscape }

    var body: some View {
        Button(action: controller.toggleTestRecording) {
            Label(isHeldKey ? "Release the key to finish" : (controller.isCapturing ? "Finish dictation" : idleTitle),
                  systemImage: controller.isCapturing ? "stop.fill" : "mic")
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(TranscriberPrimaryButtonStyle())
        .disabled(isHeldKey || (!controller.canTest && !controller.isCapturing))
        .help("Test \(controller.selectedInputName) without pasting text")
        .accessibilityIdentifier(identifier)
    }
}
