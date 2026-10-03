import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

/// C API boundary: tests supply every operation and never instantiate hardware.
struct InputAudioUnitOperations {
    var create: () throws -> AudioUnit
    var set: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeRawPointer, UInt32) -> OSStatus
    var get: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> OSStatus
    var initialize: (AudioUnit) -> OSStatus
    var start: (AudioUnit) -> OSStatus
    var stop: (AudioUnit) -> OSStatus
    var uninitialize: (AudioUnit) -> OSStatus
    var dispose: (AudioUnit) -> OSStatus
    var render: (AudioUnit, UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus

    static var live: Self {
        Self(create: {
            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
            )
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw InputAudioUnitError.driver("create input", kAudioUnitErr_FailedInitialization)
            }
            var unit: AudioUnit?
            try InputAudioUnitError.check(AudioComponentInstanceNew(component, &unit), "create input")
            guard let unit else { throw InputAudioUnitError.driver("create input", kAudioUnitErr_FailedInitialization) }
            return unit
        }, set: { AudioUnitSetProperty($0, $1, $2, $3, $4, $5) },
           get: { AudioUnitGetProperty($0, $1, $2, $3, $4, $5) },
           initialize: AudioUnitInitialize, start: AudioOutputUnitStart, stop: AudioOutputUnitStop,
           uninitialize: AudioUnitUninitialize, dispose: AudioComponentInstanceDispose,
           render: { AudioUnitRender($0, $1, $2, $3, $4, $5) })
    }
}

enum InputAudioUnitError: LocalizedError {
    case driver(String, OSStatus)
    case invalidFormat
    case routeChanged

    var errorDescription: String? {
        switch self {
        case .driver(let operation, let status): "Could not \(operation) on the selected microphone (audio error \(status)). Please try again."
        case .invalidFormat: "The selected microphone has no usable audio format."
        case .routeChanged: "The recording microphone changed or disconnected. Please try again."
        }
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw Self.driver(operation, status) }
    }
}

/// One explicit device, input enabled, output disabled. Unlike AVAudioEngine,
/// this never constructs a default input/output aggregate or follows its route.
/// All lifecycle work is serialized by AudioCaptureWorker's queue.
final class InputOnlyAudioUnit {
    private let operations: InputAudioUnitOperations
    private var unit: AudioUnit?
    private var format: AVAudioFormat?
    private var selectedDevice: AudioDeviceID?
    private var initialized = false
    private var startAttempted = false
    private var context: InputAudioRenderContext?
    private var contextReference: UnsafeMutableRawPointer?

    init(operations: InputAudioUnitOperations = .live) { self.operations = operations }

    func prepare(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        guard unit == nil else { throw AudioRecordingError.alreadyRecording }
        guard deviceID != kAudioObjectUnknown else { throw AudioRecordingError.microphoneUnavailable }
        unit = try operations.create()
        do {
            // Both directions are configured BEFORE selecting any device.
            // Only unit-local properties are written, never HAL device/default
            // properties, output routes, hog mode, or a device's sample rate.
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
            try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
            try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID)
            let hardware = try hardwareFormat()
            // Original-audio uploads support at most eight input channels.
            guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
                  hardware.mSampleRate <= 768_000,
                  hardware.mChannelsPerFrame > 0, hardware.mChannelsPerFrame <= 8 else {
                throw InputAudioUnitError.invalidFormat
            }
            // The channel-count initializer only supports mono and stereo.
            // USB interfaces expose discrete inputs, not surround speaker positions.
            let format: AVAudioFormat
            if hardware.mChannelsPerFrame > 2 {
                guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | hardware.mChannelsPerFrame) else {
                    throw InputAudioUnitError.invalidFormat
                }
                format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                                       interleaved: false, channelLayout: layout)
            } else {
                guard let monoOrStereo = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame, interleaved: false) else {
                    throw InputAudioUnitError.invalidFormat
                }
                format = monoOrStereo
            }
            // Set our client PCM layout on OUTPUT scope of INPUT element 1.
            // Keep the physical device's rate/channels; the writer resamples.
            try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee)
            try set(kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, UInt32(0))
            self.format = format
            selectedDevice = deviceID
            try validateRoute()
            return format
        } catch {
            stop()
            throw error
        }
    }

    func start(request: AudioCaptureRequest, onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onError: @escaping @Sendable (OSStatus) -> Void) throws {
        guard let unit, let format, context == nil else { throw AudioRecordingError.notRecording }
        do {
            try request.requireOpen()
            let context = InputAudioRenderContext(unit: unit, render: operations.render, request: request,
                                                 onAudio: onAudio, onError: onError)
            self.context = context
            let reference = Unmanaged.passRetained(context).toOpaque()
            contextReference = reference
            let callback = AURenderCallbackStruct(inputProc: { reference, flags, time, _, frames, _ in
                let context = Unmanaged<InputAudioRenderContext>.fromOpaque(reference).takeUnretainedValue()
                return context.receive(flags: flags, time: time, frames: frames)
            }, inputProcRefCon: reference)
            try set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
            // Mark attempts before the calls so partial failures are torn down.
            initialized = true
            try InputAudioUnitError.check(operations.initialize(unit), "initialize input")
            let maximum: UInt32 = try get(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, initial: 0)
            guard maximum > 0, maximum <= 65_536,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximum) else {
                throw InputAudioUnitError.invalidFormat
            }
            context.buffer = buffer // Immutable after start; no callbacks yet.
            try validateRoute()
            try request.requireOpen()
            startAttempted = true
            try InputAudioUnitError.check(operations.start(unit), "start input")
            guard !request.isCancelled else { throw AudioRecordingError.cancelled }
            try validateRoute(requireRunning: true)
        } catch {
            if !request.isReleased { request.cancel() }
            stop()
            throw error
        }
    }

    func validateRoute(requireRunning: Bool = false) throws {
        guard let selectedDevice, let format else { throw AudioRecordingError.notRecording }
        let current: AudioDeviceID = try get(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, initial: 0)
        let hardware = try hardwareFormat()
        guard current == selectedDevice, hardware.mSampleRate == format.sampleRate,
              hardware.mChannelsPerFrame == format.channelCount else { throw InputAudioUnitError.routeChanged }
        if requireRunning {
            let running: UInt32 = try get(kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, initial: 0)
            guard running != 0 else { throw InputAudioUnitError.routeChanged }
        }
    }

    func stop() {
        // Close admission before waiting on any driver operation. Keep callback
        // storage alive until disposal has stopped all use of its raw refCon.
        context?.request.release()
        guard let unit else { return }
        if startAttempted { report(operations.stop(unit), "stop input") }
        if initialized { report(operations.uninitialize(unit), "uninitialize input") }
        let disposed = operations.dispose(unit)
        report(disposed, "dispose input")
        if disposed == noErr, let reference = contextReference {
            Unmanaged<InputAudioRenderContext>.fromOpaque(reference).release()
        }
        // A defective driver that refuses disposal must not receive a dangling
        // refCon. In that exceptional case retain the closed gate until exit.
        contextReference = nil
        context = nil
        self.unit = nil
        format = nil
        selectedDevice = nil
        initialized = false
        startAttempted = false
    }

    private func hardwareFormat() throws -> AudioStreamBasicDescription {
        try get(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, initial: AudioStreamBasicDescription())
    }

    private func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) throws {
        guard let unit else { throw AudioRecordingError.notRecording }
        try withUnsafeBytes(of: value) { bytes in
            try InputAudioUnitError.check(operations.set(unit, property, scope, element, bytes.baseAddress!, UInt32(bytes.count)), "configure input")
        }
    }

    private func get<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, initial: T) throws -> T {
        guard let unit else { throw AudioRecordingError.notRecording }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &value) { bytes in
            try InputAudioUnitError.check(operations.get(unit, property, scope, element, bytes.baseAddress!, &size), "read input format")
        }
        guard size == MemoryLayout<T>.size else { throw InputAudioUnitError.invalidFormat }
        return value
    }

    private func report(_ status: OSStatus, _ operation: String) {
        if status != noErr {
            Logger(subsystem: "dev.davis.inlay", category: "audio-capture")
                .error("\(operation, privacy: .public) failed: \(status)")
        }
    }

    deinit { stop() }
}

/// Callback-only mutable state after start. No device queries, file writes,
/// format conversion, or UI work on the driver's real-time thread.
private final class InputAudioRenderContext {
    let unit: AudioUnit
    let render: InputAudioUnitOperations.Render
    let request: AudioCaptureRequest
    let onAudio: @Sendable (AVAudioPCMBuffer) -> Void
    let onError: @Sendable (OSStatus) -> Void
    var buffer: AVAudioPCMBuffer?
    private var failed = false

    init(unit: AudioUnit, render: @escaping InputAudioUnitOperations.Render, request: AudioCaptureRequest,
         onAudio: @escaping @Sendable (AVAudioPCMBuffer) -> Void, onError: @escaping @Sendable (OSStatus) -> Void) {
        self.unit = unit
        self.render = render
        self.request = request
        self.onAudio = onAudio
        self.onError = onError
    }

    func receive(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, time: UnsafePointer<AudioTimeStamp>, frames: UInt32) -> OSStatus {
        guard request.acceptsAudio, !failed, frames > 0 else { return noErr }
        guard let buffer, frames <= buffer.frameCapacity else {
            fail(kAudioUnitErr_TooManyFramesToProcess)
            return noErr
        }
        buffer.frameLength = frames
        let status = render(unit, flags, time, 1, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { fail(status); return noErr }
        if request.acceptsAudio { onAudio(buffer) }
        return noErr
    }

    private func fail(_ status: OSStatus) {
        failed = true
        onError(status) // Enqueues one teardown on the capture worker, never here.
    }
}

private extension InputAudioUnitOperations {
    typealias Render = (AudioUnit, UnsafeMutablePointer<AudioUnitRenderActionFlags>, UnsafePointer<AudioTimeStamp>, UInt32, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus
}
