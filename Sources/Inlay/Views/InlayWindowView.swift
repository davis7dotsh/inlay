import InlayCore
import SwiftUI

enum InlayPage: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case history = "History"
    case microphone = "Microphone"
    case server = "Server preferences"
    case device = "This Mac"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .dictation: "waveform"
        case .history: "clock.arrow.circlepath"
        case .microphone: "mic"
        case .server: "server.rack"
        case .device: "laptopcomputer"
        }
    }
}

struct InlayWindowView: View {
    @ObservedObject var controller: InlayController
    @State private var page: InlayPage

    init(controller: InlayController, initialPage: InlayPage = .dictation) {
        self.controller = controller
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    InlayAppIcon(size: 36)
                    Text("Inlay").font(.system(size: 27, weight: .regular, design: .serif))
                    DevBadge()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.top, 22)

                List(Array(InlayPage.allCases.enumerated()), id: \.element) { entry in
                    let destination = entry.element
                    Button { page = destination } label: {
                        Label(destination.rawValue, systemImage: destination.symbol)
                            .font(.callout.weight(page == destination ? .medium : .regular))
                            .foregroundStyle(page == destination ? InlayPalette.ink : InlayPalette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 37)
                            .background(page == destination ? InlayPalette.tint : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("navigation.\(destination.id)")
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                    .keyboardShortcut(KeyEquivalent(Character(String(entry.offset + 1))), modifiers: .command)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                ServerConnectionStatus(controller: controller, compact: true)
                    .padding(18)
            }
            .background { InlaySidebarSurface().ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            Group {
                switch page {
                case .dictation:
                    DictationPage(controller: controller, showPreferences: { page = .device }, showHistory: { page = .history })
                case .history: HistoryPage(controller: controller)
                case .microphone: MicrophonePage(controller: controller)
                case .server: ServerPreferencesPage(controller: controller)
                case .device: DevicePreferencesPage(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Shape-style backgrounds ignore the safe area by default; keep the
            // canvas below the titlebar so the window glass shows behind the strip.
            .background(InlayPalette.canvas, ignoresSafeAreaEdges: [])
            .overlay(alignment: .top) {
                GeometryReader { geometry in
                    InlayTitlebarGlassStrip(topInset: geometry.safeAreaInsets.top)
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
            .navigationTitle("\(InlayBuild.current.displayName) · \(page.rawValue)")
        }
        .background { InlayWindowGlassSurface().ignoresSafeArea() }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 820, minHeight: 580)
        .tint(InlayPalette.accent)
        .onExitCommand {
            if controller.isBusy && controller.canCancelWithEscape { controller.cancelDictation() }
        }
    }
}

struct DevBadge: View {
    var body: some View {
        if InlayBuild.current.isDevelopment {
            Text("Dev")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(InlayPalette.accentInk)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(InlayPalette.tint, in: Capsule())
                .accessibilityLabel("Development build")
        }
    }
}

struct ServerConnectionStatus: View {
    @ObservedObject var controller: InlayController
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(isReady: controller.isServerReady)
            Text(controller.serverStatusMessage)
                .font(compact ? .caption : .callout)
                .foregroundStyle(InlayPalette.ink)
                .lineLimit(compact ? 2 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(controller.preferences.endpoint)
                    .font(.caption)
                    .foregroundStyle(InlayPalette.muted)
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
    @ObservedObject var controller: InlayController
    var showPreferences: () -> Void
    var showHistory: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 20) {
                    InlayHoldKeyCap(key: controller.shortcut,
                                    titleOverride: controller.customTriggerKeyCode.flatMap { HoldKey.customKeyTitle(CGKeyCode($0)) },
                                    isPressed: controller.isRecording)
                    Text("\(controller.activationMode.actionVerb.capitalized) to dictate.")
                        .font(.system(size: 28, weight: .medium))
                        .tracking(-0.7)
                    Spacer()
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
                        .frame(minHeight: 120, maxHeight: .infinity)
                        .accessibilityIdentifier("dictation.transcript")
                    Divider()
                    HStack {
                        Text(controller.errorMessage ?? controller.lastDelivery)
                            .foregroundStyle(controller.errorMessage == nil ? InlayPalette.muted : InlayPalette.warning)
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
                    InlayMicrophoneTestButton(controller: controller, identifier: "dictation.test")
                    Button("History", action: showHistory)
                    Button { showPreferences() } label: { Image(systemName: "gearshape") }
                        .help("This Mac preferences")
                        .accessibilityLabel("This Mac preferences")
                }
            }
            .padding(30)
            .frame(maxWidth: InlayPageMetrics.contentWidth)
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
                        .foregroundStyle(InlayPalette.muted)
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
                    Text("A dictation finished while Inlay was closed.")
                        .font(.callout)
                        .foregroundStyle(InlayPalette.ink)
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
                    .foregroundStyle(controller.lastTranscript.isEmpty ? InlayPalette.muted : InlayPalette.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }
}

enum InlayPageMetrics {
    static let contentWidth: CGFloat = 760
    static let horizontalPadding: CGFloat = 28
}

/// The one page scaffold: flat canvas, a heading, then content capped at
/// 760 pt and centered. Form pages pass their grouped Form as content;
/// History (split list/detail) is the documented full-bleed exception.
struct InlayPageScaffold<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            // Never paint into the titlebar strip: the window glass owns it,
            // identically on every page.
            InlayPalette.canvas
            VStack(alignment: .leading, spacing: 0) {
                InlayPageHeading(title: title)
                    .frame(maxWidth: InlayPageMetrics.contentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, InlayPageMetrics.horizontalPadding)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                content
                    .frame(maxWidth: InlayPageMetrics.contentWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

struct InlayPageHeading: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 26, weight: .semibold))
            .tracking(-0.7)
            .foregroundStyle(InlayPalette.ink)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlayMicrophoneTestButton: View {
    @ObservedObject var controller: InlayController
    var identifier: String
    var idleTitle = "Test microphone"
    private var isHeldFn: Bool { controller.isCapturing && !controller.canCancelWithEscape }

    var body: some View {
        Button(action: controller.toggleTestRecording) {
            Label(isHeldFn ? "Release fn to finish" : (controller.isCapturing ? "Finish dictation" : idleTitle),
                  systemImage: controller.isCapturing ? "stop.fill" : "mic")
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(InlayPrimaryButtonStyle())
        .disabled(isHeldFn || (!controller.canTest && !controller.isCapturing))
        .help("Test \(controller.selectedInputName) without pasting text")
        .accessibilityIdentifier(identifier)
    }
}
