import Foundation

/// Device-specific preferences. Processing settings and dictation history belong to
/// the server; connection details and device identity have a separate client store.
public struct InlayConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var holdKey: String
    public var activationMode: String
    public var launchAtLogin: Bool
    /// What happens to system output while recording: none, mute, or duck.
    public var recordingOutputAudio: String
    public var dictationSoundsEnabled: Bool
    public var customTriggerKeyCode: Int?
    public var preserveClipboard: Bool
    public var microphones: MicrophonePreferences

    public static var defaultHoldKey: String { InlayBuild.current.isDevelopment ? "rightOption" : "fn" }
    public static let `default` = InlayConfiguration()

    public init(holdKey: String = InlayConfiguration.defaultHoldKey, activationMode: String = "hold", launchAtLogin: Bool = true,
                recordingOutputAudio: String = "none", dictationSoundsEnabled: Bool = true,
                customTriggerKeyCode: Int? = nil, preserveClipboard: Bool = false,
                microphones: MicrophonePreferences = MicrophonePreferences()) {
        schemaVersion = 1
        self.holdKey = holdKey
        self.activationMode = activationMode
        self.launchAtLogin = launchAtLogin
        self.recordingOutputAudio = recordingOutputAudio
        self.dictationSoundsEnabled = dictationSoundsEnabled
        self.customTriggerKeyCode = customTriggerKeyCode
        self.preserveClipboard = preserveClipboard
        self.microphones = microphones
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, holdKey, activationMode, launchAtLogin, recordingOutputAudio
        case dictationSoundsEnabled, customTriggerKeyCode, preserveClipboard, microphones
    }

    /// Read-only keys from earlier configurations.
    private enum LegacyKeys: String, CodingKey { case muteOutputWhileRecording }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.value(Int.self, for: .schemaVersion, default: 1)
        guard version == 1 else {
            throw values.invalid(.schemaVersion, "Only schemaVersion 1 is supported.")
        }
        let holdKey = try values.value(String.self, for: .holdKey, default: Self.defaultHoldKey)
        guard ["rightOption", "rightControl", "fn", "leftOption", "leftControl"].contains(holdKey) else {
            throw values.invalid(.holdKey, "Use rightOption, rightControl, fn, leftOption, or leftControl.")
        }
        let activationMode = try values.value(String.self, for: .activationMode, default: "hold")
        guard ["hold", "doubleTap", "tapToggle"].contains(activationMode) else {
            throw values.invalid(.activationMode, "Use hold, doubleTap, or tapToggle.")
        }
        // The earlier on/off mute setting carries over until the new key is written.
        let legacyMute = try decoder.container(keyedBy: LegacyKeys.self)
            .value(Bool.self, for: .muteOutputWhileRecording, default: false)
        let recordingOutputAudio = try values.value(String.self, for: .recordingOutputAudio, default: legacyMute ? "mute" : "none")
        guard ["none", "mute", "duck"].contains(recordingOutputAudio) else {
            throw values.invalid(.recordingOutputAudio, "Use none, mute, or duck.")
        }
        let customTriggerKeyCode = try values.decodeIfPresent(Int.self, forKey: .customTriggerKeyCode)
        // F1-F20 virtual key codes; keep in sync with HoldKey.recordableKeyTitles.
        let recordableKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if let customTriggerKeyCode, !recordableKeyCodes.contains(customTriggerKeyCode) {
            throw values.invalid(.customTriggerKeyCode, "Record a function key (F1-F20).")
        }
        self.init(holdKey: holdKey,
                  activationMode: activationMode,
                  launchAtLogin: try values.value(Bool.self, for: .launchAtLogin, default: true),
                  recordingOutputAudio: recordingOutputAudio,
                  dictationSoundsEnabled: try values.value(Bool.self, for: .dictationSoundsEnabled, default: true),
                  customTriggerKeyCode: customTriggerKeyCode,
                  preserveClipboard: try values.value(Bool.self, for: .preserveClipboard, default: false),
                  microphones: values.contains(.microphones)
                    ? try values.decode(StrictMicrophones.self, forKey: .microphones).preferences
                    : MicrophonePreferences())
    }
}

// Reject invalid manual edits without silently losing a microphone priority list.
private struct StrictMicrophones: Decodable {
    let preferences: MicrophonePreferences
    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let profiles = values.contains(.profiles)
            ? try values.decode([StrictProfile].self, forKey: .profiles).map(\.profile)
            : [.defaultProfile]
        guard !profiles.isEmpty, Set(profiles.map(\.id)).count == profiles.count else {
            throw values.invalid(.profiles, "Provide at least one profile, with a unique nonempty id for each.")
        }
        let activeID = try values.value(String.self, for: .activeProfileID, default: profiles[0].id)
        guard profiles.contains(where: { $0.id == activeID }) else {
            throw values.invalid(.activeProfileID, "The activeProfileID must match a profile id.")
        }
        let selection = values.contains(.selection)
            ? try values.decode(StrictSelection.self, forKey: .selection).selection : .automatic
        var preferences = MicrophonePreferences()
        preferences.profiles = profiles
        preferences.activeProfileID = activeID
        preferences.selection = selection
        self.preferences = preferences
    }
}

private struct StrictProfile: Decodable {
    let profile: MicrophoneProfile
    private enum CodingKeys: String, CodingKey { case id, name, priority }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let name = try values.value(String.self, for: .name, default: "Default")
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw values.invalid(.id, "Profile ids and names must not be empty.")
        }
        let priority = values.contains(.priority)
            ? try values.decode([StrictDevice].self, forKey: .priority).map(\.device) : []
        guard Set(priority.map(\.uid)).count == priority.count else {
            throw values.invalid(.priority, "Each microphone UID must appear only once in a priority list.")
        }
        profile = MicrophoneProfile(id: id, name: name, priority: priority)
    }
}

private struct StrictDevice: Decodable {
    let device: AudioInputDevice
    private enum CodingKeys: String, CodingKey { case uid, name, transport }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let uid = try values.decode(String.self, forKey: .uid)
        let name = try values.value(String.self, for: .name, default: "Microphone")
        let rawTransport = try values.value(String.self, for: .transport, default: "other")
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw values.invalid(.uid, "Microphone UIDs and names must not be empty.")
        }
        guard let transport = AudioInputTransport(rawValue: rawTransport) else {
            throw values.invalid(.transport, "Use builtIn, usb, bluetooth, virtual, aggregate, or other.")
        }
        device = AudioInputDevice(uid: uid, name: name, transport: transport)
    }
}

private struct StrictSelection: Decodable {
    let selection: MicrophoneSelection
    private enum CodingKeys: String, CodingKey { case mode, device }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.value(String.self, for: .mode, default: "automatic") {
        case "automatic": selection = .automatic
        case "systemDefault": selection = .systemDefault
        case "fixed": selection = .fixed(try values.decode(StrictDevice.self, forKey: .device).device)
        default: throw values.invalid(.mode, "Use automatic, systemDefault, or fixed.")
        }
    }
}

private extension KeyedDecodingContainer {
    /// A missing key chooses its default; an explicit null or wrong type is an error.
    func value<Value: Decodable>(_ type: Value.Type, for key: Key, default fallback: Value) throws -> Value {
        contains(key) ? try decode(type, forKey: key) : fallback
    }

    func invalid(_ key: Key, _ message: String) -> DecodingError {
        .dataCorruptedError(forKey: key, in: self, debugDescription: message)
    }
}
