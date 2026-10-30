import CoreAudio
import Foundation

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
    struct Entry: Codable {
        var uid: String
        var element: UInt32
    }
    struct VolumeEntry: Codable {
        var uid: String
        var element: UInt32
        var original: Float32
        var ducked: Float32
    }
    var entries: [Entry]
    var volumes: [VolumeEntry]?
}

@MainActor
final class SystemOutputMuter {
    private let client: SystemOutputClient
    private let recordURL: URL?
    private var muted: [(AudioDeviceID, AudioObjectPropertyElement)] = []
    private var ducked: [(device: AudioDeviceID, element: AudioObjectPropertyElement, original: Float32, ducked: Float32)] = []
    /// Ducked output plays at this fraction of its current volume.
    private static let duckFactor: Float32 = 0.25

    init(client: SystemOutputClient = .live, recordURL: URL? = nil) {
        self.client = client
        self.recordURL = recordURL
    }

    func mute() {
        guard let device = client.defaultOutputDevice() else { return }
        // Only elements this muter silenced are restored; anything the user had
        // already muted stays muted.
        for element in client.muteElements(device)
        where client.isMuted(device, element) == false && client.setMuted(device, element, true) {
            muted.append((device, element))
            persistRecord()
        }
    }

    func duck() {
        guard let device = client.defaultOutputDevice() else { return }
        for element in client.volumeElements(device) {
            // A pending entry from a failed restore still holds the true original.
            guard !ducked.contains(where: { $0.device == device && $0.element == element }),
                  let original = client.volume(device, element), original > 0 else { continue }
            // Core Audio may apply the write later, so record the target, not a read-back.
            let target = original * Self.duckFactor
            guard client.setVolume(device, element, target) else { continue }
            ducked.append((device, element, original, target))
            persistRecord()
        }
    }

    func restore() {
        // An unmute that fails (e.g. the output dropped mid-take) stays pending
        // so the next restore retries it instead of leaving the Mac muted.
        muted = muted.filter { device, element in !client.setMuted(device, element, false) }
        ducked = ducked.filter { entry in !client.setVolume(entry.device, entry.element, entry.original) }
        persistRecord()
    }

    /// Unmutes and unducks elements a previous crashed run recorded, then
    /// clears the record. Only listed elements are touched, and a mute or
    /// volume the user set since is never undone.
    func restorePersistedMute() {
        guard let recordURL, let data = try? Data(contentsOf: recordURL) else { return }
        defer { try? FileManager.default.removeItem(at: recordURL) }
        guard let record = try? JSONDecoder().decode(OutputMuteRecord.self, from: data) else { return }
        for entry in record.entries {
            guard let device = client.deviceID(entry.uid) else { continue }
            let element = AudioObjectPropertyElement(entry.element)
            if client.isMuted(device, element) == true {
                _ = client.setMuted(device, element, false)
            }
        }
        for entry in record.volumes ?? [] {
            guard let device = client.deviceID(entry.uid) else { continue }
            let element = AudioObjectPropertyElement(entry.element)
            if let current = client.volume(device, element), Self.isUnchanged(current, entry.ducked) {
                _ = client.setVolume(device, element, entry.original)
            }
        }
    }

    private static func isUnchanged(_ current: Float32, _ ducked: Float32) -> Bool {
        abs(current - ducked) < 0.01
    }

    private func persistRecord() {
        guard let recordURL else { return }
        if muted.isEmpty && ducked.isEmpty {
            try? FileManager.default.removeItem(at: recordURL)
            return
        }
        let entries = muted.compactMap { device, element in
            client.deviceUID(device).map { OutputMuteRecord.Entry(uid: $0, element: element) }
        }
        let volumes = ducked.compactMap { entry in
            client.deviceUID(entry.device).map {
                OutputMuteRecord.VolumeEntry(uid: $0, element: entry.element, original: entry.original, ducked: entry.ducked)
            }
        }
        guard !entries.isEmpty || !volumes.isEmpty,
              let data = try? JSONEncoder().encode(OutputMuteRecord(entries: entries, volumes: volumes))
        else { return }
        try? FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: recordURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
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
        var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<Float32>.size else { return nil }
        return value
    }

    static func setVolume(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ volume: Float32) -> Bool {
        var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value = min(max(volume, 0), 1)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    static func isMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool? {
        var address = muteAddress(element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value != 0
    }

    static func setMuted(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement, _ muted: Bool) -> Bool {
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
