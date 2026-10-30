import CoreAudio
import Foundation
import OSLog

/// What Inlay does to system output while a take is recording.
enum RecordingOutputAudio: String, CaseIterable, Identifiable {
    case none, mute, duck

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .mute: "Mute"
        case .duck: "Duck"
        }
    }
}

/// Small injection boundary between mute/duck bookkeeping and Core Audio.
struct SystemOutputClient {
    let defaultOutputDevice: () -> AudioDeviceID?
    /// Elements whose mute can be set: the main element, or each channel when a
    /// device only exposes per-channel mute.
    let muteElements: (AudioDeviceID) -> [AudioObjectPropertyElement]
    let isMuted: (AudioDeviceID, AudioObjectPropertyElement) -> Bool?
    let setMuted: (AudioDeviceID, AudioObjectPropertyElement, Bool) -> Bool
    /// Elements whose volume can be set, chosen the same way as mute elements.
    let volumeElements: (AudioDeviceID) -> [AudioObjectPropertyElement]
    let volume: (AudioDeviceID, AudioObjectPropertyElement) -> Float32?
    let setVolume: (AudioDeviceID, AudioObjectPropertyElement, Float32) -> Bool
    let deviceUID: (AudioDeviceID) -> String?
    let deviceID: (String) -> AudioDeviceID?
}

/// Elements this app muted or ducked, persisted by stable device UID so a
/// crash between mute and restore cannot strand a silent or quiet Mac.
struct OutputMuteRecord: Codable {
    struct Entry: Codable, Hashable {
        var uid: String
        var element: UInt32
    }
    struct VolumeEntry: Codable {
        var uid: String
        var element: UInt32
        var original: Float32
        var ducked: Float32

        var key: Entry { Entry(uid: uid, element: element) }
    }
    var entries: [Entry]
    var volumes: [VolumeEntry]?
}

@MainActor
final class SystemOutputMuter {
    private let client: SystemOutputClient
    private let recordURL: URL?
    // Current and unresolved older changes share one UID-based journal. Active
    // keys only defer recovery until capture ends; no device ID is kept in it.
    private var record = OutputMuteRecord(entries: [], volumes: [])
    private var recordLoaded = false
    private var activeMutes: Set<OutputMuteRecord.Entry> = []
    private var activeVolumes: Set<OutputMuteRecord.Entry> = []
    private var systemObservers: [AudioDeviceObservation] = []
    private var deviceObservers: [String: (id: AudioDeviceID, observations: [AudioDeviceObservation])] = [:]
    private var recoveryTask: Task<Void, Never>?
    private var monitoring = false
    private static let logger = Logger(subsystem: "dev.davis.inlay", category: "output-audio")
    /// Ducked output plays at this fraction of its starting volume.
    private static let duckFactor: Float32 = 0.25

    init(client: SystemOutputClient = .live, recordURL: URL? = nil) {
        self.client = client
        self.recordURL = recordURL
    }

    func mute() {
        startObserving()
        retryPending()
        guard recordLoaded, let device = client.defaultOutputDevice(),
              let uid = client.deviceUID(device), !hasChange(for: uid) else { return }
        defer { updateDeviceObservers() }
        // Only controls Inlay changed are restored; a pre-existing mute stays.
        for element in client.muteElements(device) where client.isMuted(device, element) == false {
            let entry = OutputMuteRecord.Entry(uid: uid, element: element)
            record.entries.append(entry)
            // Save the original before touching hardware. A failed journal write
            // leaves output alone rather than making an unrecoverable change.
            guard persistRecord() else { record.entries.removeLast(); continue }
            if client.setMuted(device, element, true) { activeMutes.insert(entry) }
            else {
                record.entries.removeLast()
                _ = persistRecord()
            }
        }
    }

    func duck() {
        startObserving()
        retryPending()
        guard recordLoaded, let device = client.defaultOutputDevice(),
              let uid = client.deviceUID(device), !hasChange(for: uid) else { return }
        defer { updateDeviceObservers() }
        for element in client.volumeElements(device) {
            guard let original = client.volume(device, element), original.isFinite,
                  original > 0, original <= 1 else { continue }
            // Core Audio may apply the write later, so record the target, not an
            // immediate read-back. Recovery allows scalar rounding below.
            let target = original * Self.duckFactor
            let entry = OutputMuteRecord.VolumeEntry(uid: uid, element: element, original: original, ducked: target)
            record.volumes?.append(entry)
            guard persistRecord() else { record.volumes?.removeLast(); continue }
            if client.setVolume(device, element, target) { activeVolumes.insert(entry.key) }
            else {
                record.volumes?.removeLast()
                _ = persistRecord()
            }
        }
    }

    func restore() {
        activeMutes.removeAll()
        activeVolumes.removeAll()
        retryPending()
    }

    /// Also accepts the old mute-only file. Missing devices and failed reads or
    /// writes remain journaled and are retried when hardware changes.
    func restorePersistedMute() {
        startObserving()
        retryPending()
    }

    func stop() {
        restore()
        monitoring = false
        recoveryTask?.cancel()
        recoveryTask = nil
        systemObservers.forEach { $0.cancel() }
        systemObservers.removeAll()
        deviceObservers.values.flatMap(\.observations).forEach { $0.cancel() }
        deviceObservers.removeAll()
    }

    private func hasChange(for uid: String) -> Bool {
        // Do not stack a new take (or a different mode/control layout) on an
        // unresolved original from this device. Other outputs can still change.
        record.entries.contains { $0.uid == uid } || (record.volumes ?? []).contains { $0.uid == uid }
    }

    private func retryPending() {
        guard loadRecord() else { return }
        record.entries = record.entries.filter { entry in
            guard !activeMutes.contains(entry), let device = client.deviceID(entry.uid),
                  let current = client.isMuted(device, entry.element) else { return true }
            // A readable different value relinquishes ownership to the user.
            guard current else { return false }
            return !client.setMuted(device, entry.element, false)
        }
        record.volumes = (record.volumes ?? []).filter { entry in
            guard !activeVolumes.contains(entry.key), let device = client.deviceID(entry.uid),
                  let current = client.volume(device, entry.element), current.isFinite else { return true }
            guard Self.isUnchanged(current, entry.ducked) else { return false }
            return !client.setVolume(device, entry.element, entry.original)
        }
        // On persistence failure the previous atomic file still contains the
        // originals. A later retry/save can clean it up without losing recovery.
        _ = persistRecord()
        updateDeviceObservers()
    }

    private static func isUnchanged(_ current: Float32, _ ducked: Float32) -> Bool {
        // HAL devices can quantize scalar volume writes; keep the same tolerance
        // for normal teardown and recovery instead of treating rounding as input.
        abs(current - ducked) < 0.01
    }

    private func loadRecord() -> Bool {
        guard !recordLoaded else { return true }
        guard let recordURL else { recordLoaded = true; return true }
        do {
            let data: Data
            do { data = try Data(contentsOf: recordURL) }
            catch CocoaError.fileReadNoSuchFile { recordLoaded = true; return true }
            let saved = try JSONDecoder().decode(OutputMuteRecord.self, from: data)
            // Keep the first original if an older file contains duplicates.
            var muteKeys: Set<OutputMuteRecord.Entry> = []
            var volumeKeys: Set<OutputMuteRecord.Entry> = []
            record.entries = saved.entries.filter { muteKeys.insert($0).inserted }
            record.volumes = (saved.volumes ?? []).filter { volumeKeys.insert($0.key).inserted }
            recordLoaded = true
            return true
        } catch {
            // Never overwrite an unreadable journal with a new take's snapshot.
            Self.logger.error("Cannot load output recovery journal: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    private func persistRecord() -> Bool {
        guard let recordURL else { return true }
        do {
            if record.entries.isEmpty && (record.volumes ?? []).isEmpty {
                do { try FileManager.default.removeItem(at: recordURL) }
                catch CocoaError.fileNoSuchFile { }
            } else {
                let data = try JSONEncoder().encode(record)
                try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try data.write(to: recordURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
            }
            return true
        } catch {
            Self.logger.error("Cannot save output recovery journal: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func startObserving() {
        guard !monitoring else { return }
        monitoring = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            if let observer = observe(system, selector, kAudioObjectPropertyScopeGlobal) {
                systemObservers.append(observer)
            }
        }
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioDeviceObservation? {
        AudioDeviceObservation.observe(object, selector, scope, element: kAudioObjectPropertyElementWildcard) { [weak self] in
            self?.scheduleRecovery()
        }
    }

    private func scheduleRecovery() {
        guard monitoring, recoveryTask == nil else { return }
        // One bounded debounce for a burst of HAL route/control notifications,
        // not periodic polling. Own writes can notify too; active keys are skipped.
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, monitoring else { return }
            recoveryTask = nil
            retryPending()
        }
    }

    private func updateDeviceObservers() {
        guard monitoring else { return }
        let uids = Set(record.entries.map(\.uid) + (record.volumes ?? []).map(\.uid))
        var connected: [String: AudioDeviceID] = [:]
        for uid in uids { connected[uid] = client.deviceID(uid) }
        // Resolve the UID again on every event. Reconnects can reuse or replace
        // numeric IDs; only the listener registrations retain those handles.
        for uid in Array(deviceObservers.keys) where deviceObservers[uid]?.id != connected[uid] {
            deviceObservers.removeValue(forKey: uid)?.observations.forEach { $0.cancel() }
        }
        for (uid, id) in connected where deviceObservers[uid] == nil {
            let observations = [
                observe(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
                observe(id, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput),
                observe(id, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput),
            ].compactMap { $0 }
            deviceObservers[uid] = (id, observations)
        }
    }
}

extension SystemOutputClient {
    static var live: Self {
        Self(defaultOutputDevice: SystemOutputHardware.defaultOutputID, muteElements: SystemOutputHardware.muteElements,
             isMuted: SystemOutputHardware.isMuted, setMuted: SystemOutputHardware.setMuted,
             volumeElements: SystemOutputHardware.volumeElements,
             volume: SystemOutputHardware.volume, setVolume: SystemOutputHardware.setVolume,
             deviceUID: SystemOutputHardware.deviceUID, deviceID: SystemOutputHardware.deviceID(forUID:))
    }
}

/// Uses the same mute and volume controls as the menu bar and keyboard, on the
/// default output device.
enum SystemOutputHardware {
    static func defaultOutputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func muteElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        settableElements(device, kAudioDevicePropertyMute)
    }

    static func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        settableElements(device, kAudioDevicePropertyVolumeScalar)
    }

    static func volume(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Float32? {
        guard isAlive(device) else { return nil }
        var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size else { return nil }
        return value
    }

    static func setVolume(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float32) -> Bool {
        guard isAlive(device) else { return false }
        var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value = min(max(volume, 0), 1)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func isMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool? {
        guard isAlive(device) else { return nil }
        var address = muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ muted: Bool) -> Bool {
        guard isAlive(device) else { return false }
        var address = muteAddress(element)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let uid = value?.takeRetainedValue() as String?, !uid.isEmpty else { return nil }
        return uid
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 1_048_576, size % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0 else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return nil }
        return ids.first { deviceUID($0) == uid }
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
            && size == MemoryLayout<UInt32>.size && value != 0
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        outputAddress(kAudioDevicePropertyMute, element)
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector,
                                      _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    /// The main element, or each channel when a device only exposes per-channel control.
    private static func settableElements(_ device: AudioDeviceID,
                                         _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        if isSettable(device, selector, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = AudioInputHardware.channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return [] }
        return (1...AudioObjectPropertyElement(channels)).filter { isSettable(device, selector, $0) }
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                   _ element: AudioObjectPropertyElement) -> Bool {
        var address = outputAddress(selector, element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }
}
