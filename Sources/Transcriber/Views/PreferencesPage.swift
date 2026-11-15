import TranscriberCore
import TranscriberAPI
import SwiftUI

struct DevicePreferencesPage: View {
    @ObservedObject var controller: TranscriberController

    var body: some View {
        DevicePreferencesForm(controller: controller, preferences: controller.preferences)
    }
}

private struct DevicePreferencesForm: View {
    @ObservedObject var controller: TranscriberController
    @ObservedObject var preferences: ClientPreferencesStore
    @State private var endpoint = ""
    @State private var token = ""
    @State private var deviceName = ""
    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            Section {
                TextField("Server address", text: $endpoint, prompt: Text("http://localhost:8391"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("preferences.endpoint")
                SecureField("Access token", text: $token)
                    .accessibilityIdentifier("preferences.token")
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
                TranscriberActionMessage(message: preferences.errorMessage ?? controller.errorMessage)
            } header: { Text("Connection").textCase(nil) }

            Section {
                Toggle("Mute system audio while recording", isOn: $controller.muteOutputWhileRecording)
                    .accessibilityIdentifier("preferences.mute-output")
                Text("Muting also silences VoiceOver and dictation sounds while recording.")
                    .font(.caption)
                    .foregroundStyle(TranscriberPalette.muted)
                Toggle("Play dictation sounds", isOn: $controller.dictationSoundsEnabled)
                    .accessibilityIdentifier("preferences.dictation-sounds")
                Toggle("Start \(TranscriberBuild.current.displayName) at login", isOn: $controller.launchAtLogin)
                if let error = controller.loginItemError {
                    Text(error).font(.caption).foregroundStyle(TranscriberPalette.warning)
                }
            } header: { Text("This Mac").textCase(nil) }
            .disabled(controller.isBusy)

            Section {
                ForEach(controller.shortcuts) { key in
                    HStack {
                        KeyCap(key: key)
                        Spacer()
                        Button { controller.shortcuts.removeAll { $0 == key } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(controller.shortcuts.count == 1)
                            .help(controller.shortcuts.count == 1 ? "Keep at least one key." : "Remove key")
                            .accessibilityLabel("Remove \(key.title)")
                    }
                }
                .accessibilityIdentifier("preferences.shortcut")
                HStack {
                    if controller.isAddingShortcut {
                        Text("Press a key, or pick one below. Esc cancels.").foregroundStyle(TranscriberPalette.muted)
                        Spacer()
                        Button("Cancel") { controller.finishAddingShortcut() }
                    } else {
                        Button { controller.beginAddingShortcut() } label: { Label("Add key", systemImage: "plus.circle") }
                            .buttonStyle(.borderless)
                        Spacer()
                    }
                }
                .accessibilityIdentifier("preferences.add-shortcut")
                if controller.isAddingShortcut {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], alignment: .leading, spacing: 8) {
                        ForEach(HoldKey.pickable.filter { !controller.shortcuts.contains($0) }) { key in
                            Button { controller.finishAddingShortcut(key) } label: {
                                Text(key.title).lineLimit(1).frame(maxWidth: .infinity)
                            }
                                .accessibilityIdentifier("preferences.pick-key.\(key.token)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Keys").textCase(nil)
            } footer: {
                Text("Every key starts and stops dictation the same way. For a macro pad, F13 to F20 work best. macOS often drops F21 to F24.")
                    .font(.caption)
                    .foregroundStyle(TranscriberPalette.muted)
            }
            .disabled(controller.isBusy)

            Section {
                Picker("Trigger", selection: $controller.activationMode) {
                    ForEach(HotkeyActivationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("preferences.activation")
                LabeledContent {
                    Button(controller.isCheckingShortcut ? "Stop checking" : "Check shortcut") {
                        if controller.isCheckingShortcut { controller.stopShortcutCheck() }
                        else { controller.startShortcutCheck(); showingDiagnostics = true }
                    }
                    .frame(width: 125)
                } label: {
                    Text(controller.isCheckingShortcut ? "Hold the key for a second" : "Shortcut check")
                }
                if let note = controller.shortcuts.lazy.compactMap(\.note).first {
                    Text(note).font(.caption).foregroundStyle(TranscriberPalette.muted)
                }
                DisclosureGroup("Shortcut diagnostics", isExpanded: $showingDiagnostics) {
                    ScrollView {
                        Text(controller.shortcutCheckText.isEmpty ? "Run a shortcut check to see events." : controller.shortcutCheckText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 90)
                }
            }
            .disabled(controller.isBusy)

            Section {
                PermissionRow(title: "Microphone", detail: "Capture audio while dictating.", granted: controller.permissions.microphone,
                              reviewGranted: true, action: controller.requestMicrophone)
                PermissionRow(title: "Accessibility", detail: "Recognize your dictation key and insert text.", granted: controller.permissions.accessibility,
                              reviewGranted: true, action: controller.requestAccessibility)
                HStack {
                    PermissionHelpButton()
                    Spacer()
                    Button("Check again") { controller.refreshPermissions() }
                }
            } header: { Text("Permissions").textCase(nil) }

            Section {
                HStack(spacing: 8) {
                    Text("\(TranscriberBuild.current.displayName)").font(.headline)
                    Spacer()
                    if TranscriberBuild.current.isDevelopment {
                        Text("Development build").foregroundStyle(TranscriberPalette.muted)
                    } else {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                            .foregroundStyle(TranscriberPalette.muted)
                    }
                }
                if let revision = Bundle.main.object(forInfoDictionaryKey: "TranscriberSourceRevision") as? String {
                    LabeledContent("Source revision", value: revision)
                }
                Text("Quitting this app leaves your server running.")
                    .font(.caption)
                    .foregroundStyle(TranscriberPalette.muted)
            }
        }
        .onDisappear { controller.finishAddingShortcut() }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(.switch)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .onAppear {
            endpoint = preferences.endpoint
            token = preferences.token
            deviceName = preferences.deviceName
            controller.refreshPermissions()
        }
    }
}

struct ServerPreferencesPage: View {
    @ObservedObject var controller: TranscriberController
    @State private var draft = ServerPreferences()
    @State private var base: PreferencesSnapshot?
    @State private var expandedLists = Set<String>()

    private var dirty: Bool { base.map { draft != $0.preferences } ?? false }
    private var changedRemotely: Bool {
        guard let base, let latest = controller.sharedPreferences else { return false }
        return dirty && base.revision != latest.revision
    }
    private var available: Bool { controller.sharedPreferences != nil && controller.serverHealth != nil }

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
                TranscriberActionMessage(message: changedRemotely
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
                        LabeledContent("Server version", value: health.serverVersion)
                    } header: { Text("Server models").textCase(nil) }
                }
                Section {
                    // Fork: Transcriber dictates English only, so the Language picker is removed.
                    // `draft.language` still round-trips unchanged for upstream API compatibility.
                    Toggle("Transcribe with Deepgram", isOn: $draft.deepgramSpeechEnabled)
                        .accessibilityIdentifier("preferences.deepgram-speech")
                    Text(draft.deepgramSpeechEnabled
                        ? "Faster, more accurate. Falls back to local Whisper when offline or Deepgram fails."
                        : "Local Whisper only. No audio is sent to Deepgram.")
                        .font(.caption)
                        .foregroundStyle(TranscriberPalette.muted)
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
                            .background(TranscriberPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay { RoundedRectangle(cornerRadius: 6).stroke(TranscriberPalette.muted.opacity(0.25)) }
                            .accessibilityLabel("Cleanup instructions")
                            .accessibilityIdentifier("preferences.cleanup-prompt")
                    }
                    TextField("Recognition vocabulary", text: $draft.vocabulary, axis: .vertical)
                        .lineLimit(3...5)
                        .help("Names and specialized terms to help voice recognition.")
                } header: { Text("Processing").textCase(nil) }
                .disabled(!available)

                Section {
                    Toggle("Keep original microphone audio", isOn: $draft.keepOriginalAudio)
                        .accessibilityIdentifier("preferences.keep-original")
                    Text("Whisper audio is always kept. This also saves the original microphone audio for future dictations.")
                        .font(.caption)
                        .foregroundStyle(TranscriberPalette.muted)
                } header: { Text("Shared history").textCase(nil) }
                .disabled(!available)

                Section {
                    dictionaryEditor
                } header: { Text("Dictionary").textCase(nil) }
                .disabled(!available)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toggleStyle(.switch)
        }
        .frame(maxWidth: 800)
        .frame(maxWidth: .infinity)
        .onAppear {
            loadLatest()
            controller.refreshServer()
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
                        .tint(TranscriberPalette.accentInk)
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
                    Text("\(list.entries.count)").foregroundStyle(TranscriberPalette.muted)
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
                        .foregroundStyle(TranscriberPalette.muted)
                        .lineLimit(2)
                }
                StatusDot(color: runtime.ready ? TranscriberPalette.success : TranscriberPalette.warning)
            }
        }
    }

    private func loadLatest() {
        guard let snapshot = controller.sharedPreferences else { return }
        base = snapshot
        draft = snapshot.preferences
    }
}
