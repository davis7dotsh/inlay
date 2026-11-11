import Foundation

/// Stable Core Audio identity and display metadata, never a transient hardware ID.
public struct AudioInputDevice: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let uid: String
    public let name: String
    public let transport: AudioInputTransport
    public var id: String { uid }

    public init(uid: String, name: String, transport: AudioInputTransport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    private enum CodingKeys: String, CodingKey { case uid, name, transport }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let uid = try values.decode(String.self, forKey: .uid)
        guard !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .uid, in: values, debugDescription: "An input device needs a stable UID.")
        }
        self.init(uid: uid, name: (try? values.decode(String.self, forKey: .name)) ?? "Microphone",
                  transport: (try? values.decode(AudioInputTransport.self, forKey: .transport)) ?? .other)
    }
}

public enum AudioInputTransport: String, Codable, CaseIterable, Sendable {
    case builtIn, usb, bluetooth, virtual, aggregate, other

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .other
    }
}

public struct MicrophoneProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var priority: [AudioInputDevice]

    public static let defaultProfile = MicrophoneProfile(id: "default", name: "Default")

    public init(id: String = UUID().uuidString, name: String, priority: [AudioInputDevice] = []) {
        self.id = id
        self.name = name
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey { case id, name, priority }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? values.decode(String.self, forKey: .id)) ?? "",
                  name: (try? values.decode(String.self, forKey: .name)) ?? "",
                  priority: (try? values.decode(LossyArray<AudioInputDevice>.self, forKey: .priority))?.values ?? [])
    }
}

public enum MicrophoneSelection: Equatable, Hashable, Codable, Sendable {
    case automatic
    case systemDefault
    case fixed(AudioInputDevice)

    private enum CodingKeys: String, CodingKey { case mode, device }

    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self),
              let mode = try? values.decode(String.self, forKey: .mode) else {
            self = .automatic
            return
        }
        switch mode {
        case "systemDefault": self = .systemDefault
        case "fixed":
            if let device = try? values.decode(AudioInputDevice.self, forKey: .device) {
                self = .fixed(device)
            } else {
                self = .automatic
            }
        default: self = .automatic
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try values.encode("automatic", forKey: .mode)
        case .systemDefault: try values.encode("systemDefault", forKey: .mode)
        case .fixed(let device):
            try values.encode("fixed", forKey: .mode)
            try values.encode(device, forKey: .device)
        }
    }
}

public struct MicrophonePreferences: Codable, Equatable, Sendable {
    public var profiles: [MicrophoneProfile]
    public var activeProfileID: String
    public var selection: MicrophoneSelection

    public init(profiles: [MicrophoneProfile] = [.defaultProfile], activeProfileID: String? = nil,
                selection: MicrophoneSelection = .automatic) {
        var profileIDs = Set<String>()
        let validProfiles = profiles.compactMap { profile -> MicrophoneProfile? in
            guard !profile.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  profileIDs.insert(profile.id).inserted else { return nil }
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return MicrophoneProfile(id: profile.id, name: name.isEmpty ? "Default" : name,
                                     priority: Self.uniqueDevices(profile.priority))
        }
        self.profiles = validProfiles.isEmpty ? [.defaultProfile] : validProfiles
        self.activeProfileID = self.profiles.first(where: { $0.id == activeProfileID })?.id ?? self.profiles[0].id
        if case .fixed(let device) = selection {
            self.selection = Self.uniqueDevices([device]).first.map(MicrophoneSelection.fixed) ?? .automatic
        } else {
            self.selection = selection
        }
    }

    public var activeProfile: MicrophoneProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? profiles.first ?? .defaultProfile
    }

    /// Apply after preference edits; disconnected favorites remain in their original order.
    public func normalized() -> Self {
        Self(profiles: profiles, activeProfileID: activeProfileID, selection: selection)
    }

    private enum CodingKeys: String, CodingKey { case profiles, activeProfileID, selection }

    public init(from decoder: Decoder) throws {
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            return
        }
        self.init(profiles: (try? values.decode(LossyArray<MicrophoneProfile>.self, forKey: .profiles))?.values ?? [],
                  activeProfileID: try? values.decode(String.self, forKey: .activeProfileID),
                  selection: (try? values.decode(MicrophoneSelection.self, forKey: .selection)) ?? .automatic)
    }

    fileprivate static func uniqueDevices(_ devices: [AudioInputDevice]) -> [AudioInputDevice] {
        var uids = Set<String>()
        return devices.compactMap { device in
            guard !device.uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  uids.insert(device.uid).inserted else { return nil }
            let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return AudioInputDevice(uid: device.uid, name: name.isEmpty ? "Microphone" : name,
                                    transport: device.transport)
        }
    }
}

public enum MicrophoneResolutionReason: Equatable, Sendable {
    case priority
    case fixed
    case systemDefault
    /// The chosen device was absent, or the system had no available default input.
    case fallback(requested: AudioInputDevice?)
    case unavailable
}

public struct MicrophoneResolution: Equatable, Sendable {
    public let device: AudioInputDevice?
    public let reason: MicrophoneResolutionReason
}

/// Resolves only the next recording's input. Never edits preferences or the OS default.
public enum MicrophoneSelectionPolicy {
    public static func resolve(preferences: MicrophonePreferences, available: [AudioInputDevice],
                               systemDefaultUID: String?) -> MicrophoneResolution {
        let preferences = preferences.normalized()
        let available = MicrophonePreferences.uniqueDevices(available)
        let systemDefault = available.first(where: { $0.uid == systemDefaultUID })
        // Core Audio enumeration order is not a persistent preference.
        let fallback = systemDefault ?? available.min(by: { $0.uid < $1.uid })
        guard let fallback else { return MicrophoneResolution(device: nil, reason: .unavailable) }

        switch preferences.selection {
        case .automatic:
            for preferred in preferences.activeProfile.priority {
                if let device = available.first(where: { $0.uid == preferred.uid }) {
                    return MicrophoneResolution(device: device, reason: .priority)
                }
            }
            return MicrophoneResolution(device: fallback, reason: systemDefault == nil ? .fallback(requested: nil) : .systemDefault)
        case .systemDefault:
            return MicrophoneResolution(device: fallback, reason: systemDefault == nil ? .fallback(requested: nil) : .systemDefault)
        case .fixed(let requested):
            if let device = available.first(where: { $0.uid == requested.uid }) {
                return MicrophoneResolution(device: device, reason: .fixed)
            }
            return MicrophoneResolution(device: fallback, reason: .fallback(requested: requested))
        }
    }
}

/// Salvage valid saved entries instead of losing every preference to one malformed record.
private struct LossyArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var items = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !items.isAtEnd {
            let item = try items.superDecoder()
            if let value = try? Element(from: item) { decoded.append(value) }
        }
        values = decoded
    }
}
