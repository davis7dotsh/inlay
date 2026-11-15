import Foundation

/// Device-specific preferences. Processing settings and dictation history belong to
/// the server; connection details and device identity have a separate client store.
public struct TranscriberConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    /// Fork: every listed key starts and stops dictation the same way. Each
    /// token is rightOption, rightControl, fn, or key:<virtual key code>.
    public var holdKeys: [String]
    public var activationMode: String
    public var launchAtLogin: Bool
    public var muteOutputWhileRecording: Bool
    public var dictationSoundsEnabled: Bool
    public var microphones: MicrophonePreferences
    /// Fork: keep the resolved microphone running between takes, so dictation
    /// starts without opening the device. A missing key means on.
    public var keepMicrophoneReady: Bool

    public static let `default` = TranscriberConfiguration()

    public init(holdKeys: [String] = ["rightOption"], activationMode: String = "hold", launchAtLogin: Bool = false,
                muteOutputWhileRecording: Bool = false, dictationSoundsEnabled: Bool = true,
                microphones: MicrophonePreferences = MicrophonePreferences(),
                keepMicrophoneReady: Bool = true) {
        schemaVersion = 1
        self.holdKeys = holdKeys
        self.activationMode = activationMode
        self.launchAtLogin = launchAtLogin
        self.muteOutputWhileRecording = muteOutputWhileRecording
        self.dictationSoundsEnabled = dictationSoundsEnabled
        self.microphones = microphones
        self.keepMicrophoneReady = keepMicrophoneReady
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, holdKeys, activationMode, launchAtLogin, muteOutputWhileRecording, dictationSoundsEnabled, microphones
        case keepMicrophoneReady // Fork
    }

    private enum LegacyCodingKeys: String, CodingKey { case holdKey }

    /// Key codes that can never be a "key:" token: Return (36), Tab (48),
    /// Space (49), Escape (53), keypad Enter (76) and the modifiers (54 to 63,
    /// which have presets). Return, Tab and Space must stay free for typing and
    /// for keyboard use of Add key.
    public static let reservedKeyCodes: Set<UInt16> = Set([36, 48, 49, 53, 76]).union(54...63)

    /// Accepts exactly the tokens that `HoldKey(token:)` in the app parses: a
    /// preset name, or "key:" and a canonical decimal key code that is not reserved.
    private static func isHoldKeyToken(_ token: String) -> Bool {
        if ["rightOption", "rightControl", "fn"].contains(token) { return true }
        guard token.hasPrefix("key:"), let code = UInt16(token.dropFirst(4)) else { return false }
        return token == "key:\(code)" && !reservedKeyCodes.contains(code)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.value(Int.self, for: .schemaVersion, default: 1)
        guard version == 1 else {
            throw values.invalid(.schemaVersion, "Only schemaVersion 1 is supported.")
        }
        // Fork: a file written before holdKeys names its one key in holdKey.
        let holdKeys = values.contains(.holdKeys)
            ? try values.decode([String].self, forKey: .holdKeys)
            : [try decoder.container(keyedBy: LegacyCodingKeys.self).value(String.self, for: .holdKey, default: "rightOption")]
        guard !holdKeys.isEmpty, Set(holdKeys).count == holdKeys.count, holdKeys.allSatisfy(Self.isHoldKeyToken) else {
            throw values.invalid(.holdKeys, "List one or more different keys: rightOption, rightControl, fn, or key:<code>.")
        }
        let activationMode = try values.value(String.self, for: .activationMode, default: "hold")
        guard ["hold", "doubleTap", "singleTap"].contains(activationMode) else {
            throw values.invalid(.activationMode, "Use hold, doubleTap, or singleTap.")
        }
        self.init(holdKeys: holdKeys,
                  activationMode: activationMode,
                  launchAtLogin: try values.value(Bool.self, for: .launchAtLogin, default: false),
                  muteOutputWhileRecording: try values.value(Bool.self, for: .muteOutputWhileRecording, default: false),
                  dictationSoundsEnabled: try values.value(Bool.self, for: .dictationSoundsEnabled, default: true),
                  microphones: values.contains(.microphones)
                    ? try values.decode(StrictMicrophones.self, forKey: .microphones).preferences
                    : MicrophonePreferences(),
                  keepMicrophoneReady: try values.value(Bool.self, for: .keepMicrophoneReady, default: true))
    }
}

// Reject invalid manual edits without silently losing a microphone priority list.
private struct StrictMicrophones: Decodable {
    let preferences: MicrophonePreferences
    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection, inferenceChannels }

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
        // Fork: optional per-device inference channels, keyed by stable UID.
        let inferenceChannels = values.contains(.inferenceChannels)
            ? try values.decode([String: StrictInferenceChannels].self, forKey: .inferenceChannels).mapValues(\.selection)
            : [:]
        guard inferenceChannels.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw values.invalid(.inferenceChannels, "Microphone UIDs must not be empty.")
        }
        var preferences = MicrophonePreferences()
        preferences.profiles = profiles
        preferences.activeProfileID = activeID
        preferences.selection = selection
        preferences.inferenceChannels = inferenceChannels
        self.preferences = preferences
    }
}

// Fork: `{"mode": "all"}` or `{"mode": "channels", "channelIndices": [1]}` (zero-based).
private struct StrictInferenceChannels: Decodable {
    let selection: InferenceChannelSelection
    private enum CodingKeys: String, CodingKey { case mode, channelIndices }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .mode) {
        case "all": selection = .allChannels
        case "channels":
            let indices = try values.decode([Int].self, forKey: .channelIndices)
            guard !indices.isEmpty, Set(indices).count == indices.count,
                  indices.allSatisfy({ (0..<InferenceChannelSelection.channelIndexLimit).contains($0) }) else {
                throw values.invalid(.channelIndices,
                    "List unique zero-based channel indices below \(InferenceChannelSelection.channelIndexLimit).")
            }
            selection = .channels(indices.sorted())
        default: throw values.invalid(.mode, "Use all or channels.")
        }
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
