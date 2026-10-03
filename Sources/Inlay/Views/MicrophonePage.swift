import InlayCore
import SwiftUI

struct MicrophonePage: View {
    @ObservedObject var controller: InlayController

    var body: some View {
        MicrophoneSettingsView(controller: controller, store: controller.microphones,
                               recordingInputName: controller.recordingInputName)
    }
}

private struct MicrophoneSettingsView: View {
    @ObservedObject var controller: InlayController
    @ObservedObject var store: MicrophonePreferencesStore
    var recordingInputName: String?
    @State private var editingProfile: ProfileEdit?
    @State private var confirmingRemoval = false
    @State private var dropTargetUID: String?
    @State private var draggedPriority: MicrophonePriorityDrag?
    @State private var priorityDragOffset: CGFloat = 0
    @State private var priorityRowFrames: [String: CGRect] = [:]
    @GestureState private var isPriorityDragging = false

    var body: some View {
        let profile = store.activeProfile
        let resolution = store.resolution
        let devices = store.availableDevices
        let connected = Dictionary(devices.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let preferredUIDs = Set(profile.priority.map(\.uid))
        let otherDevices = devices.filter { !preferredUIDs.contains($0.uid) }

        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                InlayPageHeading(title: "Microphone")
                inputSection(profile: profile, resolution: resolution, devices: devices)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Input priority")
                        .font(.headline)
                        .padding(.horizontal, 10)

                    InlaySettingsGroup {
                        VStack(spacing: 0) {
                            profileToolbar(profile)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                            Divider().padding(.horizontal, 16)
                            priorityList(profile: profile, connected: connected, otherDevices: otherDevices,
                                         selectedUID: store.preferences.selection == .automatic ? resolution.device?.uid : nil)
                        }
                    }

                    footer
                        .padding(.horizontal, 10)
                }
                InlayMicrophoneTestButton(controller: controller, identifier: "microphone.test")
            }
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingProfile) { edit in
            ProfileNameSheet(edit: edit, store: store)
        }
        .confirmationDialog("Delete “\(store.activeProfile.name)”?", isPresented: $confirmingRemoval) {
            Button("Delete list", role: .destructive) { _ = store.removeProfile(store.activeProfile.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this saved order is removed. Your microphones and other lists are unchanged.")
        }
    }

    private func inputSection(profile: MicrophoneProfile, resolution: MicrophoneResolution,
                              devices: [AudioInputDevice]) -> some View {
        let detail = selectionDetail(profile: profile, resolution: resolution)
        return VStack(alignment: .leading, spacing: 8) {
            InlaySettingsGroup {
                VStack(spacing: 0) {
                    HStack {
                        Text("Choose input")
                        Spacer(minLength: 16)
                        Picker("Input", selection: inputChoice) {
                            Text("Automatic · priority list").tag(MicrophoneChoice.automatic)
                            Text("System default").tag(MicrophoneChoice.systemDefault)
                            Divider()
                            ForEach(devices) { device in
                                Text(device.name).tag(MicrophoneChoice.device(device.uid))
                            }
                            if case .fixed(let device) = store.preferences.selection,
                               !devices.contains(where: { $0.uid == device.uid }) {
                                Text("\(device.name) (disconnected)").tag(MicrophoneChoice.device(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 350, alignment: .trailing)
                        .accessibilityIdentifier("microphone.input")
                    }
                    .frame(height: 48)

                    Divider()

                    HStack {
                        Text("Next dictation")
                        Spacer(minLength: 16)
                        Text(resolution.device?.name ?? "No microphone available")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(resolution.device?.name ?? "Connect an audio input to record.")
                    }
                    .frame(height: 48)
                    .accessibilityIdentifier("microphone.resolved")
                }
                .padding(.horizontal, 16)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
                .padding(.horizontal, 10)
                .help(detail)
        }
    }

    private func profileToolbar(_ profile: MicrophoneProfile) -> some View {
        HStack(spacing: 10) {
            Picker("List", selection: Binding(get: { store.preferences.activeProfileID }, set: store.selectProfile)) {
                ForEach(store.preferences.profiles) { item in
                    Text(item.name).tag(item.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Priority list")
            .accessibilityIdentifier("microphone.profile")

            Button { store.select(.automatic) } label: {
                Text(store.preferences.selection == .automatic ? "In use" : "Use list")
                    .frame(width: 56)
            }
            .disabled(store.preferences.selection == .automatic)
            .help("Automatically use the first connected microphone in this list")
            .accessibilityIdentifier("microphone.profile.use")

            Button {
                editingProfile = ProfileEdit(profileID: nil, name: "")
            } label: {
                InlayControlIcon(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New priority list")
            .accessibilityLabel("New priority list")
            .accessibilityIdentifier("microphone.profile.add")

            Menu {
                Button("Rename list…") {
                    editingProfile = ProfileEdit(profileID: profile.id, name: profile.name)
                }
                Button("Delete list…", role: .destructive) { confirmingRemoval = true }
                    .disabled(store.preferences.profiles.count == 1)
            } label: {
                InlayControlIcon(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 28)
            .help("Priority list options")
            .accessibilityLabel("Priority list options")
        }
        .controlSize(.regular)
        .frame(height: 30)
    }

    private func priorityList(profile: MicrophoneProfile, connected: [String: AudioInputDevice],
                              otherDevices: [AudioInputDevice], selectedUID: String?) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if profile.priority.isEmpty && connected.isEmpty {
                    ContentUnavailableView("No microphones connected", systemImage: "mic.slash",
                                           description: Text("Connect an audio input to add it to this list."))
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    if profile.priority.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No priorities yet")
                            Text("Add a microphone from the connected inputs below.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    }

                    ForEach(Array(profile.priority.enumerated()), id: \.element.uid) { position, device in
                        preferredRow(device, position: position, count: profile.priority.count,
                                     connected: connected[device.uid], isSelected: selectedUID == device.uid)
                    }

                    if !otherDevices.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Connected inputs")
                                .font(.caption)
                                .foregroundStyle(InlayPalette.muted)
                                .padding(.top, 18)
                                .padding(.bottom, 4)
                            ForEach(otherDevices) { device in
                                HStack(spacing: 12) {
                                    deviceLabel(device, available: true)
                                        .padding(.leading, 30)
                                    Spacer(minLength: 8)
                                    Text("Connected")
                                        .font(.caption)
                                        .foregroundStyle(InlayPalette.muted)
                                        .fixedSize()
                                    Button { store.addToPriority(device) } label: {
                                        InlayControlIcon(systemName: "plus")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(InlayPalette.accentInk)
                                    .help("Add \(device.name) to \(profile.name)")
                                    .accessibilityLabel("Add \(device.name) to priority list")
                                }
                                .frame(minHeight: 64)
                                .overlay(alignment: .bottom) { Divider() }
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
        .overlay(alignment: .topLeading) {
            priorityDragOverlay(profile: profile, connected: connected)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .coordinateSpace(name: "microphone-priorities")
        .onPreferenceChange(MicrophonePriorityFrames.self) { priorityRowFrames = $0 }
        .onChange(of: isPriorityDragging) { _, active in
            if !active { resetPriorityDrag() }
        }
        .onDisappear(perform: resetPriorityDrag)
        .padding(.horizontal, 16)
        .frame(height: 270)
        .accessibilityIdentifier("microphone.priorities")
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 7) {
            if store.storageError != nil {
                Image(systemName: "exclamationmark.circle")
                    .frame(width: 14)
            }
            Text(store.storageError ?? "Drag a handle to reorder. Disconnected microphones keep their place.")
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(store.storageError == nil ? .secondary : Color.orange)
        .frame(height: 32, alignment: .topLeading)
        .help(store.storageError ?? "In Automatic mode, the first connected microphone in the selected list is used.")
    }

    // Device names can change (or be normalized) without changing the selection.
    // Only the stable HAL UID belongs in a Picker tag.
    private var inputChoice: Binding<MicrophoneChoice> {
        Binding {
            switch store.preferences.selection {
            case .automatic: .automatic
            case .systemDefault: .systemDefault
            case .fixed(let device): .device(device.uid)
            }
        } set: { choice in
            switch choice {
            case .automatic: store.select(.automatic)
            case .systemDefault: store.select(.systemDefault)
            case .device(let uid):
                if let device = store.connectedDevice(uid: uid) { store.select(.fixed(device)) }
            }
        }
    }

    private func selectionDetail(profile: MicrophoneProfile, resolution: MicrophoneResolution) -> String {
        if let recordingInputName { return "Current take: \(recordingInputName). Changes apply to your next dictation." }
        switch resolution.reason {
        case .fallback(let requested):
            if let requested { return "\(requested.name) is disconnected. It will be used again when it reconnects." }
            return "The system input is unavailable. Using the first available microphone."
        case .unavailable: return "Connect an audio input to start dictating."
        case .priority: return "The first connected microphone in “\(profile.name)” is used."
        case .fixed: return "This microphone is preferred whenever it is connected."
        case .systemDefault:
            return store.preferences.selection == .systemDefault
                ? "Follows the macOS input. Your system settings stay unchanged."
                : "Using the macOS input until a preferred microphone is connected."
        }
    }

    private func preferredRow(_ device: AudioInputDevice, position: Int, count: Int,
                              connected: AudioInputDevice?, isSelected: Bool) -> some View {
        let isDragged = draggedPriority?.uid == device.uid && draggedPriority?.profileID == store.activeProfile.id
        return priorityRowContent(device, position: position, connected: connected)
        .opacity(isDragged ? 0.22 : 1)
        .contentShape(Rectangle())
        .background {
            if isDragged {
                RoundedRectangle(cornerRadius: 8)
                    .fill(InlayPalette.tint)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(InlayPalette.muted.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: MicrophonePriorityFrames.self,
                    value: [device.uid: geometry.frame(in: .named("microphone-priorities"))])
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .contextMenu {
            Button("Move up") { store.movePriority(uid: device.uid, by: -1) }
                .disabled(position == 0)
            Button("Move down") { store.movePriority(uid: device.uid, by: 1) }
                .disabled(position == count - 1)
            Button("Move to top") {
                store.movePriority(fromOffsets: IndexSet(integer: position), toOffset: 0)
            }
            .disabled(position == 0)
            Divider()
            Button("Remove from priority list") { store.removeFromPriority(uid: device.uid) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Priority \(position + 1), \((connected ?? device).name)")
        .accessibilityValue(connected == nil ? "Disconnected" : isSelected ? "Connected, next dictation" : "Connected")
        .accessibilityActions {
            if position > 0 {
                Button("Move up") { store.movePriority(uid: device.uid, by: -1) }
            }
            if position < count - 1 {
                Button("Move down") { store.movePriority(uid: device.uid, by: 1) }
            }
            Button("Remove from priority list") { store.removeFromPriority(uid: device.uid) }
        }
        .accessibilityIdentifier("microphone.priority.\(device.uid)")
    }

    private func priorityRowContent(_ device: AudioInputDevice, position: Int,
                                    connected: AudioInputDevice?) -> some View {
        HStack(spacing: 12) {
            Text("\(position + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(InlayPalette.muted)
                .frame(width: 18, alignment: .leading)
            deviceLabel(connected ?? device, available: connected != nil)
            Spacer(minLength: 8)
            Text(connected == nil ? "Disconnected" : "Connected")
                .font(.caption)
                .foregroundStyle(InlayPalette.muted)
                .fixedSize()
            MicrophoneReorderHandle()
                .help("Drag to reorder \(device.name)")
                .highPriorityGesture(priorityDragGesture(uid: device.uid))
        }
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private func priorityDragOverlay(profile: MicrophoneProfile, connected: [String: AudioInputDevice]) -> some View {
        if let item = draggedPriority, item.profileID == profile.id,
           let source = profile.priority.firstIndex(where: { $0.uid == item.uid }),
           let sourceFrame = priorityRowFrames[item.uid] {
            let device = profile.priority[source]
            ZStack(alignment: .topLeading) {
                priorityRowContent(device, position: source, connected: connected[device.uid])
                    .padding(.horizontal, 10)
                    .frame(width: sourceFrame.width, height: sourceFrame.height)
                    .background(InlayPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(InlayPalette.accentInk.opacity(0.65), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                    .position(x: sourceFrame.midX, y: sourceFrame.midY + priorityDragOffset)

                // Draw last so the exact insertion edge remains visible above the lifted row.
                if let targetUID = dropTargetUID,
                   let target = profile.priority.firstIndex(where: { $0.uid == targetUID }),
                   let targetFrame = priorityRowFrames[targetUID] {
                    HStack(spacing: 0) {
                        Circle().frame(width: 7, height: 7)
                        Rectangle().frame(height: 3)
                        Circle().frame(width: 7, height: 7)
                    }
                    .foregroundStyle(InlayPalette.accentInk)
                    .frame(width: targetFrame.width, height: 7)
                    .position(x: targetFrame.midX, y: target > source ? targetFrame.maxY : targetFrame.minY)
                }
            }
        }
    }

    private func priorityDragGesture(uid: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("microphone-priorities"))
            .updating($isPriorityDragging) { _, active, _ in active = true }
            .onChanged { value in
                if draggedPriority == nil {
                    draggedPriority = MicrophonePriorityDrag(profileID: store.activeProfile.id, uid: uid)
                }
                priorityDragOffset = value.translation.height
                dropTargetUID = priorityUID(at: value.location.y)
            }
            .onEnded { value in
                defer { resetPriorityDrag() }
                guard let item = draggedPriority, let targetUID = priorityUID(at: value.location.y) else { return }
                movePriority(item, to: targetUID)
            }
    }

    private func resetPriorityDrag() {
        draggedPriority = nil
        dropTargetUID = nil
        priorityDragOffset = 0
    }

    private func priorityUID(at y: CGFloat) -> String? {
        store.activeProfile.priority.compactMap { device -> (uid: String, distance: CGFloat)? in
            guard let frame = priorityRowFrames[device.uid] else { return nil }
            return (device.uid, abs(frame.midY - y))
        }.min(by: { $0.distance < $1.distance })?.uid
    }

    private func movePriority(_ item: MicrophonePriorityDrag, to targetUID: String) {
        let profile = store.activeProfile
        guard item.profileID == profile.id,
              let source = profile.priority.firstIndex(where: { $0.uid == item.uid }),
              let target = profile.priority.firstIndex(where: { $0.uid == targetUID }) else { return }
        store.movePriority(fromOffsets: IndexSet(integer: source), toOffset: target > source ? target + 1 : target)
    }

    private func deviceLabel(_ device: AudioInputDevice, available: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.transport.symbol)
                .font(.system(size: 15))
                .foregroundStyle(available ? InlayPalette.accentInk : InlayPalette.muted)
                .frame(width: 20, height: 24)
                .accessibilityHidden(true)
            Text(device.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(available ? InlayPalette.ink : InlayPalette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MicrophonePriorityDrag {
    var profileID: String
    var uid: String
}

private struct MicrophonePriorityFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct MicrophoneReorderHandle: View {
    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(InlayPalette.muted)
        .frame(width: 28, height: 28)
        .background(InlayPalette.surface.opacity(0.001))
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

private enum MicrophoneChoice: Hashable {
    case automatic
    case systemDefault
    case device(String)
}

private struct ProfileEdit: Identifiable {
    let id = UUID()
    let profileID: String?
    let name: String
}

private struct ProfileNameSheet: View {
    let edit: ProfileEdit
    @ObservedObject var store: MicrophonePreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(edit.profileID == nil ? "New priority list" : "Rename priority list")
                .font(.headline)
            TextField("Name", text: $name, prompt: Text("Desk, travel…"))
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityIdentifier("microphone.profile.name")
                .onChange(of: name) { _, _ in error = nil }
            Text(error ?? "Each list remembers its own microphone order.")
                .font(.caption)
                .foregroundStyle(error == nil ? .secondary : Color.orange)
                .frame(height: 30, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.profileID == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
        .onAppear {
            name = edit.name
            focused = true
        }
    }

    private func save() {
        let result = edit.profileID.map { store.renameProfile($0, to: name) } ?? store.addProfile(named: name)
        switch result {
        case .success: dismiss()
        case .failure(let failure): error = failure.localizedDescription
        }
    }
}

private extension AudioInputTransport {
    var symbol: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "mic"
        case .bluetooth: "headphones"
        case .virtual: "waveform.path"
        case .aggregate: "square.stack.3d.up"
        case .other: "mic"
        }
    }
}
