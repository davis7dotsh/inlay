import CoreAudio
import Foundation
import InlayCore

/// AudioDeviceIDs are ephemeral HAL handles. Only stable UIDs leave this layer.
struct AudioInputHandle: Equatable {
    let deviceID: AudioDeviceID
    let device: AudioInputDevice
}

struct AudioHardwareSnapshot: Equatable {
    let deviceIDs: [AudioDeviceID]
    let inputs: [AudioInputHandle]
    let systemDefaultID: AudioDeviceID?
}

/// Small injection boundary so inventory/lifecycle tests never open audio hardware.
struct AudioHardwareClient {
    let snapshot: () -> AudioHardwareSnapshot
    let observe: (AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, @escaping @MainActor () -> Void) -> AudioDeviceObservation?

    static var live: Self {
        Self(snapshot: AudioInputHardware.snapshot, observe: AudioDeviceObservation.observe)
    }
}

/// Reads HAL metadata only: no AVAudioEngine, capture session, permission request,
/// or write to the Mac's default input device is needed to populate the picker.
@MainActor
final class AudioDeviceStore {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemDefaultUID: String?
    var onChange: (([AudioInputDevice], String?) -> Void)?

    private let hardware: AudioHardwareClient
    private var handlesByUID: [String: AudioDeviceID] = [:]
    private var systemObservers: [AudioDeviceObservation] = []
    private var deviceObservers: [AudioDeviceID: [AudioDeviceObservation]] = [:]
    private var monitoring = false

    init(hardware: AudioHardwareClient = .live) {
        self.hardware = hardware
    }

    func start() {
        guard !monitoring else { return }
        monitoring = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            if let observer = observe(system, selector, kAudioObjectPropertyScopeGlobal) {
                systemObservers.append(observer)
            }
        }
        refresh()
    }

    func refresh() {
        let snapshot = hardware.snapshot()
        if monitoring { updateDeviceObservers(snapshot.deviceIDs) }

        var handles: [String: AudioDeviceID] = [:]
        let available = snapshot.inputs.filter { input in
            guard !input.device.uid.isEmpty, handles[input.device.uid] == nil else { return false }
            handles[input.device.uid] = input.deviceID
            return true
        }.map(\.device).sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.uid < right.uid : order == .orderedAscending
        }
        let defaultUID = snapshot.inputs.first { $0.deviceID == snapshot.systemDefaultID }?.device.uid
        let changed = devices != available || systemDefaultUID != defaultUID || handlesByUID != handles
        devices = available
        systemDefaultUID = defaultUID
        handlesByUID = handles
        if changed { onChange?(devices, systemDefaultUID) }
    }

    func deviceID(for uid: String) -> AudioDeviceID? {
        handlesByUID[uid]
    }

    func stop() {
        monitoring = false
        systemObservers.forEach { $0.cancel() }
        deviceObservers.values.flatMap { $0 }.forEach { $0.cancel() }
        systemObservers.removeAll()
        deviceObservers.removeAll()
    }

    private func observe(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioDeviceObservation? {
        hardware.observe(object, selector, scope) { [weak self] in
            guard let self, self.monitoring else { return }
            self.refresh()
        }
    }

    private func updateDeviceObservers(_ deviceIDs: [AudioDeviceID]) {
        let connected = Set(deviceIDs)
        for id in Set(deviceObservers.keys).subtracting(connected) {
            deviceObservers.removeValue(forKey: id)?.forEach { $0.cancel() }
        }
        // Include output-only/not-yet-alive devices here: their stream or alive
        // property may change without a new numeric device ID being allocated.
        for id in connected where deviceObservers[id] == nil {
            deviceObservers[id] = [
                observe(id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal),
                observe(id, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            ].compactMap { $0 }
        }
    }
}

/// A matched add/remove pair retains the exact block and dispatch queue CoreAudio
/// requires. Cancellation is idempotent; deallocation also unregisters listeners.
final class AudioDeviceObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = cancellation
        cancellation = nil
        action?()
    }

    deinit { cancel() }

    static func observe(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ onChange: @escaping @MainActor () -> Void
    ) -> AudioDeviceObservation? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            // None of these metadata properties use the real-time IO callback.
            MainActor.assumeIsolated { onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return AudioDeviceObservation {
            var removalAddress = address
            AudioObjectRemovePropertyListenerBlock(object, &removalAddress, .main, block)
        }
    }
}

enum AudioInputHardware {
    static func snapshot() -> AudioHardwareSnapshot {
        let deviceIDs = allDeviceIDs()
        let inputs = deviceIDs.compactMap { id -> AudioInputHandle? in
            guard isAvailable(id), let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { return nil }
            let name = string(id, kAudioObjectPropertyName).flatMap { $0.isEmpty ? nil : $0 } ?? "Unnamed microphone"
            let transport = transport(uint32(id, kAudioDevicePropertyTransportType))
            return AudioInputHandle(deviceID: id, device: AudioInputDevice(uid: uid, name: name, transport: transport))
        }
        return AudioHardwareSnapshot(deviceIDs: deviceIDs, inputs: inputs, systemDefaultID: defaultInputID())
    }

    static func defaultInputID() -> AudioDeviceID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func isAvailable(_ id: AudioDeviceID) -> Bool {
        id != kAudioObjectUnknown && uint32(id, kAudioDevicePropertyDeviceIsAlive) == 1 && hasInputChannels(id)
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 1_048_576, size % UInt32(MemoryLayout<AudioDeviceID>.stride) == 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.stride))
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        // HAL's CFString metadata properties transfer ownership to the caller.
        let result = value?.takeRetainedValue()
        guard status == noErr else { return nil }
        return result as String?
    }

    private static func hasInputChannels(_ id: AudioDeviceID) -> Bool {
        channelCount(id, scope: kAudioObjectPropertyScopeInput) > 0
    }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<UInt32>.size, size <= 1_048_576 else { return 0 }
        let allocationSize = max(Int(size), MemoryLayout<AudioBufferList>.stride)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: allocationSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: allocationSize)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return 0 }
        let list = memory.assumingMemoryBound(to: AudioBufferList.self)
        let bufferOffset = MemoryLayout<AudioBufferList>.stride - MemoryLayout<AudioBuffer>.stride
        guard Int(size) >= bufferOffset,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - bufferOffset) / MemoryLayout<AudioBuffer>.stride else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transport(_ rawValue: UInt32?) -> AudioInputTransport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual: .virtual
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .aggregate
        default: .other
        }
    }
}
