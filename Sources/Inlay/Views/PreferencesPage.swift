import InlayCore
import InlayAPI
import SwiftUI

struct DevicePreferencesPage: View {
    @ObservedObject var controller: InlayController

    var body: some View {
        InlayPageScaffold(title: "This Mac") {
            DevicePreferencesForm(controller: controller, preferences: controller.preferences,
                                  configuration: controller.configuration)
        }
    }
}

private struct DevicePreferencesForm: View {
    @ObservedObject var controller: InlayController
    @ObservedObject var preferences: ClientPreferencesStore
    @ObservedObject var configuration: ConfigurationStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var deviceName = ""
    @State private var showingDiagnostics = false
    @State private var deviceToRevoke: DeviceSummary?
    @StateObject private var triggerRecorder = TriggerKeyRecorder()

    private var usesPlainHTTP: Bool { (try? ServerEndpoint(endpoint))?.usesPlainHTTP ?? false }

    private var recordingOutputAudioCaption: String {
        switch controller.recordingOutputAudio {
        case .none: "Leaves system audio unchanged while recording."
        case .mute: "Silences system audio, VoiceOver and dictation sounds. Unsupported outputs stay unchanged."
        case .duck: "Lowers system audio, including VoiceOver, to a quarter of its starting volume. Unsupported outputs stay unchanged."
        }
    }

    var body: some View {
        Form {
            Section {
                if !InlayBuild.current.isDevelopment {
                    LocalServerSetupSection(controller: controller)
                    Divider()
                }
                TextField("Server address", text: $endpoint, prompt: Text("http://localhost:8391"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("preferences.endpoint")
                SecureField("Server token", text: $token)
                    .accessibilityIdentifier("preferences.token")
                Text(InlayBuild.current.isDevelopment
                    ? "Paste the admin token (.local/dev-server/token) once; this Mac then keeps its own revocable credential."
                    : "Paste the server's admin token once (admin-token in its data folder, or its --token-file); this Mac then keeps its own revocable credential.")
                    .font(.caption)
                    .foregroundStyle(InlayPalette.muted)
                TextField("Device name", text: $deviceName)
                    .accessibilityIdentifier("preferences.device-name")
                HStack {
                    ServerConnectionStatus(controller: controller)
                    Button("Connect") {
                        controller.errorMessage = nil
                        controller.saveConnection(endpoint: endpoint, token: token, deviceName: deviceName)
                    }
                        .disabled(controller.isBusy || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("preferences.connect")
                }
                InlayActionMessage(message: preferences.errorMessage ?? controller.errorMessage)
                if usesPlainHTTP {
                    Text("This connection is unencrypted unless Tailscale carries it.")
                        .font(.caption)
                        .foregroundStyle(InlayPalette.warning)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if controller.serverHealth != nil {
                        ForEach(controller.devices, id: \.id) { device in
                            HStack {
                                Text(device.name)
                                if device.id == preferences.deviceID {
                                    Text("This Mac").font(.caption).foregroundStyle(InlayPalette.muted)
                                }
                                Spacer()
                                if let revoked = device.revokedAt {
                                    Text("Revoked \(revoked.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(InlayPalette.muted)
                                } else {
                                    if let seen = device.lastSeenAt {
                                        Text(seen.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption).foregroundStyle(InlayPalette.muted)
                                    }
                                    if device.id != preferences.deviceID {
                                        Button("Revoke") { deviceToRevoke = device }
                                    }
                                }
                            }
                        }
                        if !controller.legacyEnrollmentClosed {
                            HStack {
                                Text("The old shared token can still enroll new Macs.").font(.caption)
                                Spacer()
                                Button("Stop accepting it") { controller.closeLegacyEnrollment() }
                            }
                        }
                    }
                }
                .frame(minHeight: 52, alignment: .topLeading)
            } header: { Text("Connection").textCase(nil) }

            Section {
                Picker("Dictation key", selection: Binding<HoldKey?>(
                    get: { controller.customTriggerKeyCode == nil ? controller.shortcut : nil },
                    set: { if let key = $0 { controller.customTriggerKeyCode = nil; controller.shortcut = key } }
                )) {
                    ForEach(HoldKey.allCases) { key in
                        if key == .fn { Text(key.title).tag(Optional(key)) }
                        else { Text(key.title).tag(Optional(key)) }
                    }
                }
                .accessibilityIdentifier("preferences.shortcut")
                LabeledContent {
                    HStack {
                        if triggerRecorder.isRecording {
                            Button("Cancel") { triggerRecorder.stop() }
                        } else {
                            Button("Record key") {
                                triggerRecorder.start { code in controller.customTriggerKeyCode = code }
                            }
                            if controller.customTriggerKeyCode != nil {
                                Button("Clear") { controller.customTriggerKeyCode = nil }
                            }
                        }
                    }
                } label: {
                    Text(triggerRecorder.isRecording
                        ? "Press a function key (Esc cancels)"
                        : "Custom key: \(controller.customTriggerKeyCode.flatMap { HoldKey.customKeyTitle(CGKeyCode($0)) } ?? "None")")
                }
                .disabled(controller.isBusy)
                if let rejection = triggerRecorder.rejection {
                    Text(rejection).font(.caption).foregroundStyle(InlayPalette.warning)
                }
                Picker("Trigger", selection: $controller.activationMode) {
                    ForEach(HotkeyActivationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("preferences.activation")
                if controller.activationMode == .tapToggle {
                    Text("Recording continues until you tap again, press the stop button, or reach 3 minutes.")
                        .font(.caption)
                        .foregroundStyle(InlayPalette.muted)
                }
                LabeledContent {
                    Button(controller.isCheckingShortcut ? "Stop checking" : "Check shortcut") {
                        if controller.isCheckingShortcut { controller.stopShortcutCheck() }
                        else { controller.startShortcutCheck(); showingDiagnostics = true }
                    }
                    .frame(width: 125)
                } label: {
                    Text(controller.isCheckingShortcut ? "Hold the key for a second" : "Shortcut check")
                }
                if let note = controller.shortcut.note { Text(note).font(.caption).foregroundStyle(InlayPalette.muted) }
                DisclosureGroup("Shortcut diagnostics", isExpanded: $showingDiagnostics) {
                    ScrollView {
                        Text(controller.shortcutCheckText.isEmpty ? "Run a shortcut check to see events." : controller.shortcutCheckText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
                Picker("System audio while recording", selection: $controller.recordingOutputAudio) {
                    ForEach(RecordingOutputAudio.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("preferences.mute-output")
                Text(recordingOutputAudioCaption)
                .font(.caption)
                .foregroundStyle(InlayPalette.muted)
                .lineLimit(2, reservesSpace: true)
                Toggle("Play dictation sounds", isOn: $controller.dictationSoundsEnabled)
                    .accessibilityIdentifier("preferences.dictation-sounds")
                Toggle("Never leave transcripts on the clipboard", isOn: $controller.preserveClipboard)
                    .accessibilityIdentifier("preferences.preserve-clipboard")
                Toggle("Start \(InlayBuild.current.displayName) at login", isOn: $controller.launchAtLogin)
                if let error = controller.loginItemError {
                    Text(error).font(.caption).foregroundStyle(InlayPalette.warning)
                }
                if let error = configuration.errorMessage {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(InlayPalette.warning)
                        Button("Reveal config file") { configuration.revealFile() }
                    }
                }
            } header: { Text("This Mac").textCase(nil) }
            .disabled(controller.isBusy)

            Section {
                PermissionRow(title: "Microphone", detail: "Capture audio while dictating.", granted: controller.permissions.microphone,
                              reviewGranted: true, action: controller.requestMicrophone)
                PermissionRow(title: "Accessibility", detail: "Insert text at your cursor and recognize your dictation key anywhere.", granted: controller.permissions.accessibility,
                              reviewGranted: true, action: controller.requestAccessibility)
                PermissionRow(title: "Input Monitoring", detail: "Recognize your dictation key. With only this permission, dictations are copied, not inserted.", granted: controller.permissions.inputMonitoring,
                              reviewGranted: true, action: controller.requestInputMonitoring)
                if !controller.permissions.accessibility && controller.permissions.inputMonitoring {
                    Text("Shortcut is on. Dictations will be copied, not inserted; paste with Command-V.")
                        .font(.caption)
                        .foregroundStyle(InlayPalette.muted)
                } else if !controller.permissions.accessibility && !controller.permissions.inputMonitoring {
                    Text("Shortcut is off. Allow Accessibility (insert anywhere) or Input Monitoring (copy mode).")
                        .font(.caption)
                        .foregroundStyle(InlayPalette.warning)
                }
                HStack {
                    PermissionHelpButton()
                    Spacer()
                    Button("Check again") { controller.refreshPermissions() }
                }
            } header: { Text("Permissions").textCase(nil) }

            Section {
                HStack(spacing: 8) {
                    Text("\(InlayBuild.current.displayName)").font(.headline)
                    Spacer()
                    if InlayBuild.current.isDevelopment {
                        Text("Development build").foregroundStyle(InlayPalette.muted)
                    } else {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .foregroundStyle(InlayPalette.muted)
                    }
                }
                Text("Quitting this app leaves your server running.")
                    .font(.caption)
                    .foregroundStyle(InlayPalette.muted)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity)
        .onAppear {
            endpoint = preferences.endpoint
            token = preferences.token
            deviceName = preferences.deviceName
            controller.refreshPermissions()
            Task { await controller.refreshDevices() }
        }
        .onChange(of: preferences.token) { _, newToken in token = newToken }
        .confirmationDialog("Revoke this device?", isPresented: Binding(
            get: { deviceToRevoke != nil }, set: { if !$0 { deviceToRevoke = nil } })) {
            Button("Revoke", role: .destructive) {
                if let device = deviceToRevoke { controller.revokeDevice(device.id) }
                deviceToRevoke = nil
            }
            Button("Cancel", role: .cancel) { deviceToRevoke = nil }
        } message: {
            Text("It will lose access to this server immediately.")
        }
    }
}

struct ServerPreferencesPage: View {
    @ObservedObject var controller: InlayController
    @State private var draft = ServerPreferences()
    @State private var base: PreferencesSnapshot?
    @State private var expandedLists = Set<String>()
    @State private var confirmingPurgeOriginal = false
    @State private var confirmingPurgeAll = false

    private var dirty: Bool { base.map { draft != $0.preferences } ?? false }
    private var changedRemotely: Bool {
        guard let base, let latest = controller.sharedPreferences else { return false }
        return dirty && base.revision != latest.revision
    }
    private var available: Bool { controller.sharedPreferences != nil && controller.serverHealth != nil }
    // The wire values form a closed enum; keep them stable. Other Parakeet
    // languages use automatic proofreading without adding enum cases.
    private let languages = [
        ("English", "en"), ("Automatic", "auto"), ("Spanish", "es"), ("French", "fr"),
        ("German", "de"), ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"),
        ("Polish", "pl"), ("Russian", "ru"), ("Ukrainian", "uk"), ("Swedish", "sv"),
        ("Japanese (proofreading only)", "ja"), ("Chinese (proofreading only)", "zh"),
        ("Korean (proofreading only)", "ko"), ("Hindi (proofreading only)", "hi"),
        ("Arabic (proofreading only)", "ar")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ServerConnectionStatus(controller: controller)
                Button("Discard changes") { loadLatest() }
                    .opacity(dirty ? 1 : 0)
                    .disabled(!dirty)
                Button("Save shared preferences") {
                    controller.errorMessage = nil
                    controller.updateSharedPreferences(draft, expectedRevision: base?.revision)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!available || !dirty || changedRemotely || draft.validationError != nil || controller.isSavingPreferences)
                .accessibilityIdentifier("preferences.save-shared")
            }
            .frame(height: 34)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 10)

            HStack {
                InlayActionMessage(message: !available
                    ? "Cannot load shared preferences while the server is unavailable."
                    : changedRemotely
                        ? "Shared preferences changed on another device. Reload to continue."
                        : (draft.validationError ?? controller.errorMessage))
                Button("Reload") { loadLatest() }
                    .opacity(changedRemotely ? 1 : 0)
                    .disabled(!changedRemotely)
            }
            .padding(.horizontal, 28)

            Form {
                if let health = controller.serverHealth {
                    Section {
                        runtimeRow("Voice", runtime: health.speech)
                        runtimeRow("Proofreading", runtime: health.proofreading)
                    if let serverVersion = controller.serverHealth?.serverVersion {
                        LabeledContent("Server version", value: serverVersion)
                    }
                    } header: { Text("Server models").textCase(nil) }
                }
                Section {
                    Picker("Proofreading language", selection: $draft.language) {
                        ForEach(languages, id: \.1) { name, code in Text(name).tag(code) }
                    }
                    Text("Parakeet recognizes 25 European languages automatically. Use Automatic for other proofreading languages.")
                        .font(.caption).foregroundStyle(InlayPalette.muted)
                    Toggle("Proofread with Qwen", isOn: $draft.textCorrectionEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Cleanup instructions")
                            Spacer()
                            Button("Reset to default") {
                                draft.proofreadingPrompt = ServerPreferences.defaultProofreadingPrompt
                            }
                            .disabled(draft.proofreadingPrompt == ServerPreferences.defaultProofreadingPrompt)
                            .accessibilityIdentifier("preferences.reset-cleanup-prompt")
                        }
                        TextEditor(text: $draft.proofreadingPrompt)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .padding(7)
                            .frame(height: 352)
                            .background(InlayPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).stroke(InlayPalette.muted.opacity(0.25)) }
                            .accessibilityLabel("Cleanup instructions")
                            .accessibilityIdentifier("preferences.cleanup-prompt")
                    }
                } header: { Text("Processing").textCase(nil) }
                .disabled(!available)

                Section {
                    Toggle("Keep original microphone audio", isOn: $draft.keepOriginalAudio)
                        .accessibilityIdentifier("preferences.keep-original")
                    Picker("Keep audio", selection: $draft.audioRetentionDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                        Text("Forever").tag(0)
                    }
                    .accessibilityIdentifier("preferences.audio-retention")
                    Text("Transcription and original audio are removed after this period; text is always kept. Keeping originals also saves the original microphone audio for future dictations.")
                        .font(.caption)
                        .foregroundStyle(InlayPalette.muted)
                    if let usage = controller.storageUsage {
                        LabeledContent("Recording audio", value: ByteCountFormatter.string(fromByteCount: usage.audioByteCount, countStyle: .file))
                        LabeledContent("Transcription audio", value: ByteCountFormatter.string(fromByteCount: usage.inferenceByteCount, countStyle: .file))
                        LabeledContent("Original audio", value: ByteCountFormatter.string(fromByteCount: usage.originalByteCount, countStyle: .file))
                        LabeledContent("Recordings", value: "\(usage.generationCount)")
                        if let oldest = usage.oldestAudioAt {
                            LabeledContent("Oldest audio", value: oldest.formatted(date: .abbreviated, time: .omitted))
                        }
                        LabeledContent("Free on server", value: ByteCountFormatter.string(fromByteCount: usage.freeByteCount, countStyle: .file))
                        HStack {
                            Button("Delete original audio") { confirmingPurgeOriginal = true }
                            Button("Delete all audio") { confirmingPurgeAll = true }
                        }
                    }
                } header: { Text("Shared history").textCase(nil) }
                .disabled(!available)
                .confirmationDialog("Delete all original audio?", isPresented: $confirmingPurgeOriginal) {
                    Button("Delete original audio", role: .destructive) { controller.purgeAudio(kind: .original) }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Transcripts and transcription audio stay. This cannot be undone.") }
                .confirmationDialog("Delete all recording audio?", isPresented: $confirmingPurgeAll) {
                    Button("Delete all audio", role: .destructive) { controller.purgeAudio(kind: nil) }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Transcripts stay in history. This cannot be undone.") }

                Section {
                    dictionaryEditor
                } header: { Text("Dictionary").textCase(nil) }
                .disabled(!available)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toggleStyle(.switch)
        }
        .frame(maxWidth: InlayPageMetrics.contentWidth)
        .frame(maxWidth: .infinity)
        .onAppear {
            loadLatest()
            controller.refreshServer()
            Task { await controller.refreshStorageUsage() }
        }
        .onChange(of: controller.sharedPreferences) { old, latest in
            if base == nil || !dirty || latest?.preferences == draft {
                loadLatest()
            }
        }
    }

    @ViewBuilder private var dictionaryEditor: some View {
        ForEach($draft.dictionary.lists) { $list in
            DisclosureGroup(isExpanded: Binding(
                get: { expandedLists.contains(list.id) },
                set: { if $0 { expandedLists.insert(list.id) } else { expandedLists.remove(list.id) } }
            )) {
                TextField("List name", text: $list.name)
                ForEach($list.entries) { $entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Preferred spelling", text: $entry.term)
                            TextField("Words or phrases to replace, separated by commas", text: Binding(
                                get: { entry.aliases.joined(separator: ", ") },
                                set: { value in
                                    entry.aliases = value.isEmpty ? [] : value.components(separatedBy: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                }
                            ))
                            .font(.caption)
                            .help("Use narrow phrases: preferred ‘auth middleware’, replace ‘off middleware’. Replacing ‘off’ alone also changes ordinary uses of that word.")
                        }
                        Toggle(isOn: $entry.isPriority) {
                            Image(systemName: entry.isPriority ? "star.fill" : "star")
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.borderless)
                        .tint(InlayPalette.accentInk)
                        .help("Priority words are suggested first when model space is limited.")
                        .accessibilityLabel("Prioritize \(entry.term.isEmpty ? "word" : entry.term)")
                        .accessibilityIdentifier("preferences.dictionary-priority.\(entry.id)")
                        Button {
                            list.entries.removeAll { $0.id == entry.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove word")
                            .accessibilityLabel("Remove \(entry.term.isEmpty ? "word" : entry.term)")
                    }
                    .padding(.vertical, 6)
                }
                HStack {
                    Button("Add word") { list.entries.append(DictionaryEntry(term: "")) }
                    Spacer()
                    Button("Remove list", role: .destructive) {
                        draft.dictionary.lists.removeAll { $0.id == list.id }
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text(list.name.isEmpty ? "New list" : list.name)
                    Spacer()
                    Text("\(list.entries.count)").foregroundStyle(InlayPalette.muted)
                }
            }
        }
        Button("Add list") {
            let list = DictionaryList(name: "New list")
            draft.dictionary.lists.append(list)
            expandedLists.insert(list.id)
        }
    }

    private func runtimeRow(_ title: String, runtime: ModelRuntimeInfo) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(runtime.modelID).lineLimit(1)
                    Text(runtime.message ?? runtime.backend)
                        .font(.caption)
                        .foregroundStyle(InlayPalette.muted)
                        .lineLimit(2)
                }
                StatusDot(isReady: runtime.ready)
            }
        }
    }

    private func loadLatest() {
        guard let snapshot = controller.sharedPreferences else { return }
        base = snapshot
        draft = snapshot.preferences
    }
}


/// Captures one function-key press for the custom trigger. Text-typing keys
/// are rejected (with a message) instead of recorded, so an Escape press
/// always cancels.
@MainActor
final class TriggerKeyRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var rejection: String?
    private var monitor: Any?

    func start(onCapture: @escaping (Int) -> Void) {
        stop()
        isRecording = true
        rejection = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                if event.keyCode == 53 {
                    self.stop()
                    return nil
                }
                if HoldKey.recordableKeyTitles[event.keyCode] != nil {
                    let code = Int(event.keyCode)
                    self.stop()
                    onCapture(code)
                    return nil
                }
                self.rejection = "That key types or is a modifier. Choose a function key (F1-F20), or Esc to cancel."
                return nil
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}


private struct LocalServerSetupSection: View {
    @ObservedObject var controller: InlayController
    @ObservedObject var downloads: ModelDownloadManager
    @ObservedObject var server: LocalServerManager

    init(controller: InlayController) {
        self.controller = controller
        downloads = controller.modelDownloads
        server = controller.localServer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Speech model", installed: downloads.speechStatus == .installed) {
                downloads.downloadSpeechModel()
            }
            statusRow("Text model", installed: downloads.textStatus == .installed) {
                downloads.downloadTextModel()
            }
            HStack {
                Text("Local server")
                Spacer()
                switch server.state {
                case .installed:
                    Text("Installed").foregroundStyle(InlayPalette.success)
                    Button("Use this server") { controller.completeLocalSetup() }
                    Button("Uninstall") { controller.uninstallLocalServer() }
                case .installing(let step):
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(InlayPalette.muted)
                case .failed(let message):
                    Text(message).foregroundStyle(InlayPalette.warning).lineLimit(2)
                    Button("Try again") { Task { await server.install() } }
                case .notInstalled:
                    if server.portOccupiedByOther {
                        Text("A server you set up yourself is already running. Connect to it below.")
                            .font(.caption).foregroundStyle(InlayPalette.muted)
                    } else {
                        Button("Set up on this Mac") { Task { await server.install() } }
                            .disabled(downloads.speechStatus != .installed || downloads.textStatus != .installed)
                    }
                }
            }
            if server.state == .installed, controller.serverHealth == nil {
                Text("Installed but not reachable yet. It may still be starting; use Connect below, or check ~/Library/Logs/Inlay/server.log.")
                    .font(.caption)
                    .foregroundStyle(InlayPalette.warning)
            }
            if let error = downloads.errorMessage {
                Text(error).font(.caption).foregroundStyle(InlayPalette.warning)
            }
        }
        .onAppear {
            downloads.refreshStatus()
            Task { await server.detect() }
        }
    }

    private func statusRow(_ title: String, installed: Bool, download: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if installed {
                Text("Installed").foregroundStyle(InlayPalette.success)
            } else if downloads.isDownloading {
                ProgressView().controlSize(.small)
                Button("Cancel") { downloads.cancelDownloads() }
            } else {
                Button("Download") { download() }
            }
        }
    }
}
