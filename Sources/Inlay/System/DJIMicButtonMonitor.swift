import Foundation
import IOKit.hid
import IOKit.hidsystem

/// The Mic Mini / Mini 2 / Mini 2S USB receiver's consumer-control interface.
/// IDs and volume usages are documented by caezium/dji-mic-wispr-flow.
enum DJIMicButton {
    static let vendorID = 0x2CA3
    static let productID = 0x4011
    static let consumerPage: UInt32 = 0x0C
    static let volumeUsages: Set<UInt32> = [0xE9, 0xEA]

    static func matches(vendorID: Int, productID: Int, usagePage: UInt32, usage: UInt32) -> Bool {
        vendorID == Self.vendorID && productID == Self.productID
            && usagePage == consumerPage && volumeUsages.contains(usage)
    }
}

/// One toggle per physical press, including receivers that report both usages.
struct DJIMicButtonPressState {
    private var down: Set<UInt32> = []
    private var lastPress: TimeInterval?

    mutating func seed(usage: UInt32, isDown: Bool) {
        if isDown { down.insert(usage) }
    }

    mutating func receive(usage: UInt32, value: Int, at time: TimeInterval) -> Bool {
        guard DJIMicButton.volumeUsages.contains(usage) else { return false }
        if value == 0 { down.remove(usage); return false }
        let wasDown = !down.isEmpty
        down.insert(usage)
        guard !wasDown, lastPress.map({ time - $0 >= 0.3 }) ?? true else { return false }
        lastPress = time
        return true
    }
}

enum DJIMicButtonStatus: Equatable {
    case disabled, paused, permissionRequired, waiting, ready, unavailable

    var message: LocalizedStringResource {
        switch self {
        case .disabled: "Button control is off."
        case .paused: "Button control is paused while your Mac is away."
        case .permissionRequired: "Allow Input Monitoring to use the DJI button."
        case .waiting: "Connect the DJI receiver by USB-C."
        case .ready: "DJI receiver connected. Press the linking button to dictate."
        case .unavailable: "Could not capture the DJI button. Disable other DJI button mappings, then check again."
        }
    }
}

@MainActor
final class DJIMicButtonMonitor {
    var onPress: ((UInt64) -> Void)?
    var onDisconnect: ((UInt64) -> Void)?
    var onStatusChange: ((DJIMicButtonStatus) -> Void)?
    private(set) var status: DJIMicButtonStatus = .disabled {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }
    private var manager: IOHIDManager?
    private var managerLifetime: HotkeyCancellation?
    private struct Receiver {
        let lifetime: HotkeyCancellation
        var presses: DJIMicButtonPressState
    }
    private var receivers: [UInt64: Receiver] = [:]
    private var failedDevices: Set<UInt64> = []

    func refresh(enabled: Bool, suspended: Bool) {
        guard enabled, !suspended else {
            stop()
            status = enabled ? .paused : .disabled
            return
        }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            stop()
            status = .permissionRequired
            return
        }
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        self.manager = manager
        managerLifetime = HotkeyCancellation {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        // Only seize the consumer HID interface. Audio and ordinary keyboards
        // remain independent; no system-wide key remapping is installed.
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: DJIMicButton.vendorID,
            kIOHIDProductIDKey: DJIMicButton.productID,
            kIOHIDDeviceUsagePageKey: Int(DJIMicButton.consumerPage),
            kIOHIDDeviceUsageKey: 1,
            kIOHIDTransportKey: "USB",
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, _, device in
            guard let context, result == kIOReturnSuccess else { return }
            MainActor.assumeIsolated {
                Unmanaged<DJIMicButtonMonitor>.fromOpaque(context).takeUnretainedValue().connect(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<DJIMicButtonMonitor>.fromOpaque(context).takeUnretainedValue().disconnect(device)
            }
        }, context)
        status = .waiting
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if IOHIDManagerOpen(manager, 0) != kIOReturnSuccess {
            stop()
            status = .unavailable
        }
    }

    func retry(enabled: Bool, suspended: Bool) {
        stop()
        refresh(enabled: enabled, suspended: suspended)
    }

    func stop() {
        guard manager != nil else { return }
        self.manager = nil
        managerLifetime?.cancel()
        managerLifetime = nil
        let previous = receivers
        receivers.removeAll()
        failedDevices.removeAll()
        for (id, receiver) in previous {
            receiver.lifetime.cancel()
            onDisconnect?(id)
        }
        status = .disabled
    }

    private func connect(_ device: IOHIDDevice) {
        guard manager != nil, let id = deviceID(device), receivers[id] == nil else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else {
            failedDevices.insert(id)
            updateStatus()
            return
        }
        failedDevices.remove(id)
        var presses = DJIMicButtonPressState()
        let matching = [kIOHIDElementUsagePageKey: Int(DJIMicButton.consumerPage)] as CFDictionary
        if let elements = IOHIDDeviceCopyMatchingElements(device, matching, 0) as? [IOHIDElement] {
            for element in elements where DJIMicButton.volumeUsages.contains(IOHIDElementGetUsage(element)) {
                withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer in
                    if let pointer = buffer.baseAddress, IOHIDDeviceGetValue(device, element, pointer) == kIOReturnSuccess {
                        let value = pointer.pointee.takeUnretainedValue()
                        presses.seed(usage: IOHIDElementGetUsage(element), isDown: IOHIDValueGetIntegerValue(value) != 0)
                    }
                }
            }
        }
        let lifetime = HotkeyCancellation {
            IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        }
        receivers[id] = Receiver(lifetime: lifetime, presses: presses)
        IOHIDDeviceSetInputValueMatching(device, matching)
        IOHIDDeviceRegisterInputValueCallback(device, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            MainActor.assumeIsolated {
                Unmanaged<DJIMicButtonMonitor>.fromOpaque(context).takeUnretainedValue().receive(value)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        updateStatus()
    }

    private func disconnect(_ device: IOHIDDevice) {
        guard let id = deviceID(device) else { return }
        failedDevices.remove(id)
        if let receiver = receivers.removeValue(forKey: id) {
            receiver.lifetime.cancel()
            onDisconnect?(id)
        }
        updateStatus()
    }

    private func receive(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let id = deviceID(device), receivers[id] != nil,
              let vendor = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int,
              let product = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int,
              DJIMicButton.matches(vendorID: vendor, productID: product,
                                   usagePage: IOHIDElementGetUsagePage(element), usage: IOHIDElementGetUsage(element)) else { return }
        if receivers[id]?.presses.receive(usage: IOHIDElementGetUsage(element), value: IOHIDValueGetIntegerValue(value),
                                         at: ProcessInfo.processInfo.systemUptime) == true {
            onPress?(id)
        }
    }

    private func deviceID(_ device: IOHIDDevice) -> UInt64? {
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == kIOReturnSuccess ? id : nil
    }

    private func updateStatus() {
        status = !receivers.isEmpty ? .ready : (failedDevices.isEmpty ? .waiting : .unavailable)
    }
}
