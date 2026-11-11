import Combine
import Foundation
import InlayCore

enum MicrophoneProfileError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case lastProfile
    case missingProfile

    var errorDescription: String? {
        switch self {
        case .emptyName: "Give the priority list a name."
        case .duplicateName: "A priority list already has that name."
        case .lastProfile: "Keep at least one priority list."
        case .missingProfile: "That priority list is no longer available."
        }
    }
}

/// Preferences and connected-device snapshots, with no microphone ownership.
@MainActor
final class MicrophonePreferencesStore: ObservableObject {
    @Published private(set) var preferences: MicrophonePreferences
    @Published private(set) var availableDevices: [AudioInputDevice] = []
    @Published private(set) var systemDefaultUID: String?
    @Published private(set) var storageError: String?
    private let configuration: ConfigurationStore
    private var subscriptions: Set<AnyCancellable> = []

    init(configuration: ConfigurationStore) {
        self.configuration = configuration
        preferences = configuration.configuration.microphones
        storageError = configuration.errorMessage
        configuration.$configuration
            .map(\.microphones)
            .removeDuplicates()
            .sink { [weak self] value in self?.preferences = value }
            .store(in: &subscriptions)
        configuration.$errorMessage
            .removeDuplicates()
            .sink { [weak self] message in self?.storageError = message }
            .store(in: &subscriptions)
    }

    var activeProfile: MicrophoneProfile { preferences.activeProfile }
    var resolution: MicrophoneResolution {
        MicrophoneSelectionPolicy.resolve(preferences: preferences, available: availableDevices, systemDefaultUID: systemDefaultUID)
    }
    var otherDevices: [AudioInputDevice] {
        let preferred = Set(activeProfile.priority.map(\.uid))
        return availableDevices.filter { !preferred.contains($0.uid) }
    }

    func connectedDevice(uid: String) -> AudioInputDevice? {
        availableDevices.first { $0.uid == uid }
    }

    func update(devices: [AudioInputDevice], systemDefaultUID: String?) {
        if availableDevices != devices { availableDevices = devices }
        if self.systemDefaultUID != systemDefaultUID { self.systemDefaultUID = systemDefaultUID }
        guard configuration.isLoaded else { return }
        // Refresh names/transport without forgetting offline favorites or order.
        var next = preferences
        for index in next.profiles.indices {
            next.profiles[index].priority = next.profiles[index].priority.map { connectedDevice(uid: $0.uid) ?? $0 }
        }
        if case .fixed(let device) = next.selection, let connected = connectedDevice(uid: device.uid) {
            next.selection = .fixed(connected)
        }
        save(next)
    }

    func select(_ selection: MicrophoneSelection) {
        var next = preferences
        next.selection = selection
        save(next)
    }

    func selectProfile(_ id: String) {
        guard preferences.profiles.contains(where: { $0.id == id }) else { return }
        var next = preferences
        next.activeProfileID = id
        save(next)
    }

    func addProfile(named name: String) -> Result<Void, MicrophoneProfileError> {
        switch validatedName(name) {
        case .failure(let error): return .failure(error)
        case .success(let name):
            var next = preferences
            let profile = MicrophoneProfile(name: name)
            next.profiles.append(profile)
            next.activeProfileID = profile.id
            save(next)
            return .success(())
        }
    }

    func renameProfile(_ id: String, to name: String) -> Result<Void, MicrophoneProfileError> {
        guard let index = preferences.profiles.firstIndex(where: { $0.id == id }) else { return .failure(.missingProfile) }
        switch validatedName(name, excluding: id) {
        case .failure(let error): return .failure(error)
        case .success(let name):
            var next = preferences
            next.profiles[index].name = name
            save(next)
            return .success(())
        }
    }

    func removeProfile(_ id: String) -> Result<Void, MicrophoneProfileError> {
        guard preferences.profiles.contains(where: { $0.id == id }) else { return .failure(.missingProfile) }
        guard preferences.profiles.count > 1 else { return .failure(.lastProfile) }
        var next = preferences
        next.profiles.removeAll { $0.id == id }
        save(next)
        return .success(())
    }

    func addToPriority(_ device: AudioInputDevice) {
        editPriority { entries in
            guard !entries.contains(where: { $0.uid == device.uid }) else { return }
            entries.append(device)
        }
    }

    func removeFromPriority(uid: String) {
        editPriority { $0.removeAll { $0.uid == uid } }
    }

    func movePriority(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        editPriority { entries in
            let indices = offsets.filter { entries.indices.contains($0) }
            guard !indices.isEmpty, (0...entries.count).contains(destination) else { return }
            let moved = indices.map { entries[$0] }
            let selected = Set(indices)
            var remaining = entries.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
            let insertion = destination - indices.filter { $0 < destination }.count
            remaining.insert(contentsOf: moved, at: insertion)
            entries = remaining
        }
    }

    func movePriority(uid: String, by offset: Int) {
        editPriority { entries in
            guard [-1, 1].contains(offset), let index = entries.firstIndex(where: { $0.uid == uid }),
                  entries.indices.contains(index + offset) else { return }
            entries.swapAt(index, index + offset)
        }
    }

    private func editPriority(_ edit: (inout [AudioInputDevice]) -> Void) {
        var next = preferences
        guard let index = next.profiles.firstIndex(where: { $0.id == next.activeProfileID }) else { return }
        edit(&next.profiles[index].priority)
        save(next)
    }

    private func validatedName(_ name: String, excluding id: String? = nil) -> Result<String, MicrophoneProfileError> {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !preferences.profiles.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            return .failure(.duplicateName)
        }
        return .success(name)
    }

    private func save(_ value: MicrophonePreferences) {
        let value = value.normalized()
        guard value != preferences else { return }
        configuration.update { $0.microphones = value }
    }
}
