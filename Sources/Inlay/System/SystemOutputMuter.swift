import CoreAudio
import Foundation

/// Small injection boundary so mute/restore tests never touch the Mac's output.
struct SystemOutputClient {
    let defaultOutputDevice: () -> AudioDeviceID?
    /// Elements whose mute can be set: the main element, or each channel when a
    /// device only exposes per-channel mute.
    let muteElements: (AudioDeviceID) -> [AudioObjectPropertyElement]
    let isMuted: (AudioDeviceID, AudioObjectPropertyElement) -> Bool?
    let setMuted: (AudioDeviceID, AudioObjectPropertyElement, Bool) -> Bool
    let deviceUID: (AudioDeviceID) -> String?
    let deviceID: (String) -> AudioDeviceID?
}

/// Elements this app muted, persisted by stable device UID so a crash
/// between mute and restore cannot strand a silent Mac.
struct OutputMuteRecord: Codable {
    struct Entry: Codable {
        var uid: String
        var element: UInt32
    }
    var entries: [Entry]
}

@MainActor
final class SystemOutputMuter {
    private let client: SystemOutputClient
    private let recordURL: URL?
    private var muted: [(AudioDeviceID, AudioObjectPropertyElement)] = []

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

    func restore() {
        // An unmute that fails (e.g. the output dropped mid-take) stays pending
        // so the next restore retries it instead of leaving the Mac muted.
        muted = muted.filter { device, element in !client.setMuted(device, element, false) }
        persistRecord()
    }

    /// Unmutes elements a previous crashed run recorded, then clears the
    /// record. Only listed elements are touched; a user mute is never undone.
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
    }

    private func persistRecord() {
        guard let recordURL else { return }
        if muted.isEmpty {
            try? FileManager.default.removeItem(at: recordURL)
            return
        }
        let entries = muted.compactMap { device, element in
            client.deviceUID(device).map { OutputMuteRecord.Entry(uid: $0, element: element) }
        }
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(OutputMuteRecord(entries: entries))
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
             deviceUID: SystemOutputHardware.deviceUID, deviceID: SystemOutputHardware.deviceID(forUID:))
    }
}

/// Uses the same mute control as the menu bar and keyboard, on the default
/// output device. Volume levels are never changed.
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
        if isSettable(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        let channels = AudioInputHardware.channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        guard channels > 0 else { return [] }
        return (1...AudioObjectPropertyElement(channels)).filter { isSettable(device, $0) }
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
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func isSettable(_ device: AudioDeviceID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = muteAddress(element)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }
}
