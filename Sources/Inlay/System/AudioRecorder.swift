import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import InlayCore
import OSLog

struct CapturedAudio: Sendable {
    let duration: TimeInterval
    /// Absolute sample peak, in the range 0...1 for normal microphone audio.
    let peak: Float

    /// Removes temporary capture directories written by earlier builds.
    static func cleanupOrphans(in temporaryDirectory: URL = InlayTemporaryDirectory.url) {
        let files = FileManager.default
        guard let entries = try? files.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isCapture = ["Inlay-Dev-recording-"].contains { prefix in
                name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
            }
            if isCapture { try? files.removeItem(at: entry) }
        }
    }
}

enum AudioRecordingError: LocalizedError {
    case permissionRequired
    case alreadyRecording
    case notRecording
    case microphoneUnavailable
    case microphoneSelectionFailed(OSStatus)
    case conversionUnavailable
    case noAudio
    case cancelled
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow microphone access in System Settings first."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no recording to finish."
        case .microphoneUnavailable: "The selected microphone is unavailable. Choose another input in Inlay."
        case .microphoneSelectionFailed(let status): "This microphone could not be opened (audio error \(status)). Choose another input in Inlay."
        case .conversionUnavailable: "This microphone's audio format could not be converted. Try another input device."
        case .noAudio: "The microphone did not provide any audio."
        case .cancelled: "The recording was cancelled."
        case .processing(let message): "Could not save microphone audio: \(message)"
        }
    }
}

/// Owns the hardware only between explicit start() and stop()/cancel() calls.
@MainActor
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    var onInterruption: ((String) -> Void)?

    private let worker: AudioCaptureWorker
    private let microphoneAuthorized: () -> Bool
    private let sleepNotifications: NotificationCenter
    private var request: AudioCaptureRequest?
    private var sleepObserver: NSObjectProtocol?

    init(worker: AudioCaptureWorker? = nil,
         microphoneAuthorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
         sleepNotifications: NotificationCenter? = nil) {
        self.worker = worker ?? AudioCaptureWorker(makeHardware: { QueuedAudioHardware(queue: $0) })
        self.microphoneAuthorized = microphoneAuthorized
        self.sleepNotifications = sleepNotifications ?? NSWorkspace.shared.notificationCenter
    }

    /// PCM goes to `spool` as it is captured; the caller owns the spool.
    func start(deviceID: AudioDeviceID? = nil, preserveOriginalAudio: Bool = false, spool: RecordingSpool) async throws {
        guard request == nil else { throw AudioRecordingError.alreadyRecording }
        guard microphoneAuthorized() else { throw AudioRecordingError.permissionRequired }
        guard !Task.isCancelled else { throw AudioRecordingError.cancelled }
        let current = AudioCaptureRequest(spool: spool)
        request = current
        sleepObserver = sleepNotifications.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.interrupt(id: current.id, message: "Recording stopped because your Mac is going to sleep.")
            }
        }
        do {
            try await worker.start(
                request: current, deviceID: deviceID,
                preserveOriginalAudio: preserveOriginalAudio,
                onLevel: { [weak self] level in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.request?.id == current.id, current.acceptsAudio else { return }
                        self.onLevel?(level)
                    }
                },
                onInterruption: { [weak self] message in
                    DispatchQueue.main.async { [weak self] in
                        self?.interrupt(id: current.id, message: message)
                    }
                }
            )
            guard !Task.isCancelled else {
                worker.cancel(request: current)
                throw AudioRecordingError.cancelled
            }
        } catch {
            if let audioError = error as? InputAudioUnitError {
                Logger(subsystem: "dev.davis.inlay", category: "audio-capture")
                    .error("Capture startup failed: \(audioError.localizedDescription, privacy: .public)")
            }
            // A release can race a slow startup failure. Retain that request
            // until stop() consumes it, so a quick hold becomes noAudio rather
            // than accidentally stopping or publishing into a later take.
            if request?.id == current.id, !current.isReleased {
                request = nil
                removeSleepObserver()
                onLevel?(0)
            }
            throw error
        }
    }

    /// Call directly on key release, before scheduling the async stop task.
    /// No tap arriving after this gate closes may admit additional PCM.
    func stopAcceptingAudio() {
        request?.release()
        onLevel?(0)
    }

    func stop() async throws -> CapturedAudio {
        let stopped = stopCapture()
        return try await withTaskCancellationHandler {
            try await stopped.value
        } onCancel: { stopped.cancel() }
    }

    /// Transfer the released request synchronously, before a new hold or cancel
    /// can reach this recorder. The returned task owns only this take's teardown.
    func stopCapture() -> Task<CapturedAudio, Error> {
        guard let current = request else { return Task { throw AudioRecordingError.notRecording } }
        current.release()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        return Task { try await worker.stop(request: current) }
    }

    func cancel() {
        let current = request
        current?.cancel()
        request = nil
        removeSleepObserver()
        onLevel?(0)
        if let current { worker.cancel(request: current) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id else { return }
        // Do not cancel here: the controller salvages the take through the
        // normal stop path so queued microphone buffers are drained.
        onInterruption?(message)
    }

    private func removeSleepObserver() {
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
        sleepObserver = nil
    }

    deinit {
        if let request { worker.cancel(request: request) }
        if let sleepObserver { sleepNotifications.removeObserver(sleepObserver) }
    }
}

/// Capture queue ownership is independent of the Mac's default output route.
private final class QueuedAudioHardware: AudioCaptureHardware, @unchecked Sendable {
    private let queue: DispatchQueue
    private var inputUnit: InputOnlyAudioUnit?
    private var writer: RecordingWriter?
    private var request: AudioCaptureRequest?
    private var onInterruption: (@Sendable (String) -> Void)?
    private var selectedDevice: AudioDeviceID?
    private var deviceObservers: [AudioDeviceObservation] = []

    init(queue: DispatchQueue) { self.queue = queue }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws {
        try request.requireOpen()
        guard inputUnit == nil else { throw AudioRecordingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecordingError.permissionRequired
        }
        guard let selectedDevice = deviceID ?? AudioInputHardware.defaultInputID(),
              AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
        self.request = request
        self.onInterruption = onInterruption
        self.selectedDevice = selectedDevice
        let inputUnit = InputOnlyAudioUnit()
        self.inputUnit = inputUnit
        let format = try inputUnit.prepare(deviceID: selectedDevice)
        try request.requireOpen()
        let id = request.id
        let writer = try RecordingWriter(
            inputFormat: format, spool: request.spool, preserveOriginalAudio: preserveOriginalAudio, onLevel: onLevel,
            onError: { [weak self] message in self?.enqueueInterruption(id: id, message: message) }
        )
        self.writer = writer
        deviceObservers = [
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(selectedDevice, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
            AudioDeviceObservation.observe(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal) { [weak self] in
                self?.enqueueRouteCheck(id: id)
            },
        ].compactMap { $0 }
        try inputUnit.start(request: request, onAudio: { buffer in writer.append(buffer) }, onError: { [weak self] status in
            self?.enqueueInterruption(id: id, message: InputAudioUnitError.driver("read input", status).localizedDescription)
        })
        guard AudioInputHardware.isAvailable(selectedDevice) else { throw AudioRecordingError.microphoneUnavailable }
    }

    func stop() -> RecordingWriter? {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        return currentWriter
    }

    func cancel() {
        request?.release()
        let currentWriter = writer
        detachMicrophone()
        currentWriter?.cancel()
    }

    private func enqueueRouteCheck(id: UUID) {
        queue.async { [weak self] in
            guard let self, self.request?.id == id, self.request?.acceptsAudio == true,
                  let selectedDevice = self.selectedDevice, let inputUnit = self.inputUnit else { return }
            do {
                guard AudioInputHardware.isAvailable(selectedDevice) else { throw InputAudioUnitError.routeChanged }
                try inputUnit.validateRoute(requireRunning: true)
            } catch {
                self.interrupt(id: id, message: error.localizedDescription)
            }
        }
    }

    private func enqueueInterruption(id: UUID, message: String) {
        queue.async { [weak self] in self?.interrupt(id: id, message: message) }
    }

    private func interrupt(id: UUID, message: String) {
        guard request?.id == id, request?.acceptsAudio == true else { return }
        Logger(subsystem: "dev.davis.inlay", category: "audio-capture")
            .error("Capture interrupted: \(message, privacy: .public)")
        let callback = onInterruption
        // Stop admitting PCM immediately, but keep the writer. The normal
        // stop path must drain its queue and converter before sealing. Calling
        // cancel() here used to race a shorter, already-uploaded prefix.
        request?.release()
        callback?(message)
    }

    private func detachMicrophone() {
        deviceObservers.forEach { $0.cancel() }
        deviceObservers.removeAll()
        inputUnit?.stop()
        inputUnit = nil
        writer = nil
        request = nil
        selectedDevice = nil
        onInterruption = nil
    }

    deinit { cancel() }
}

/// Mirrors appendAudio's original format and stream-size limits. Check bytes
/// as they are captured: even a high-rate device can archive a short take.
enum OriginalAudioPolicy {
    static let maximumBytes: Int64 = 4_000_000_000

    static func isArchivable(sampleRate: Double, channels: Int) -> Bool {
        (8_000...192_000).contains(sampleRate) && sampleRate.rounded() == sampleRate && (1...8).contains(channels)
    }
}

/// Only the admission gate is shared between the audio callback and the caller.
/// Converter, files, counters, and errors are confined to the serial writer queue.
final class RecordingWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.inlay.audio-writer", qos: .userInitiated)
    private let admissionLock = NSLock()
    private var accepting = true
    private var queuedBytes = 0
    private var inputOverrun = false
    // A blocked filesystem must interrupt and save the admitted prefix, not
    // turn hours of input into unbounded queued buffers and get the app killed.
    private let maximumQueuedBytes = 32 * 1024 * 1024

    private let spool: RecordingSpool
    private let format: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let onLevel: (Float) -> Void
    private let onError: (String) -> Void
    private var file: FileHandle?
    private var originalFile: FileHandle?
    private var originalBytes: Int64 = 0
    private var failure: Error?
    private var frames: AVAudioFramePosition = 0
    private var inputFrames: AVAudioFramePosition = 0
    private var unsyncedFrames: AVAudioFramePosition = 0
    private var peak: Float = 0
    private var meter = AudioLevelMeter()
    private var meterSumSquares = 0.0
    private var meterFrames = 0
    private let meterWindowFrames = 800 // 50 ms at the 16 kHz inference rate.
    /// Checkpoint every ten seconds of processed audio, off the input thread.
    private let syncFrames: AVAudioFramePosition = 160_000
    private var maximumFrames: AVAudioFramePosition { AVAudioFramePosition(16_000 * spool.maximumSeconds) }
    private var maximumInputFrames: AVAudioFramePosition {
        AVAudioFramePosition(inputFormat.sampleRate * Double(spool.maximumSeconds))
    }

    init(inputFormat: AVAudioFormat, spool: RecordingSpool, preserveOriginalAudio: Bool = false,
         onLevel: @escaping (Float) -> Void, onError: @escaping (String) -> Void) throws {
        let conversionInput: AVAudioFormat
        if inputFormat.channelCount > 2 {
            guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate,
                                           channels: 1, interleaved: false) else {
                throw AudioRecordingError.conversionUnavailable
            }
            conversionInput = mono
        } else {
            conversionInput = inputFormat
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: conversionInput, to: format) else {
            throw AudioRecordingError.conversionUnavailable
        }
        self.spool = spool
        self.format = format
        self.inputFormat = inputFormat
        self.converter = converter
        self.onLevel = onLevel
        self.onError = onError
        converter.downmix = true
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        // The upload format is float32; InputOnlyAudioUnit negotiates it. Any
        // other input still records speech, just without the archival copy.
        let keepsOriginal = preserveOriginalAudio
            && inputFormat.commonFormat == .pcmFormatFloat32
            && OriginalAudioPolicy.isArchivable(sampleRate: inputFormat.sampleRate,
                                                channels: Int(inputFormat.channelCount))
        func open(_ url: URL) throws -> FileHandle {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AudioRecordingError.processing("The recording file could not be created.")
            }
            return try FileHandle(forWritingTo: url)
        }
        file = try open(spool.inferenceURL)
        // Persist the PCM directory entry before accepting any microphone data.
        try RecordingSpool.syncDirectory(spool.directory)
        if keepsOriginal {
            do {
                originalFile = try open(spool.originalURL)
                try spool.update {
                    $0.originalSampleRate = Int(inputFormat.sampleRate)
                    $0.originalChannels = Int(inputFormat.channelCount)
                }
            } catch { omitOriginal() }
        }
    }

    func append(_ source: AVAudioPCMBuffer) {
        // The input unit reuses its buffers. Copy only PCM memory here; never run
        // conversion, metering, UI work, or disk I/O on the real-time callback.
        let length = Int(source.frameLength) * Int(source.format.channelCount) * MemoryLayout<Float>.size
        guard length > 0 else { return }
        admissionLock.lock()
        defer { admissionLock.unlock() }
        guard accepting, !inputOverrun else { return }
        guard length <= maximumQueuedBytes - queuedBytes,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            inputOverrun = true
            // Notify even if the writer is blocked. stop() will drain the
            // admitted prefix and flush its converter; nothing after the gap
            // is admitted. The callback only schedules capture-queue work.
            onError("The Mac could not keep up with the microphone.")
            return
        }
        copy.frameLength = source.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }
        queuedBytes += length
        queue.async { [self] in
            process(copy)
            admissionLock.withLock { queuedBytes -= length }
        }
    }

    func finish() async throws -> CapturedAudio {
        try await withCheckedThrowingContinuation { continuation in
            admissionLock.lock()
            guard accepting else {
                admissionLock.unlock()
                continuation.resume(throwing: AudioRecordingError.cancelled)
                return
            }
            accepting = false
            queue.async { [self] in
                let result = Result {
                    if let failure { throw failure }
                    try flushConverter()
                    guard frames > 0 else { throw AudioRecordingError.noAudio }
                    return CapturedAudio(duration: Double(frames) / format.sampleRate, peak: peak)
                }
                // Quit waits on this continuation. Do not resume until the
                // final checkpoint and close have actually finished.
                do {
                    try closeFiles()
                    continuation.resume(with: result)
                } catch { continuation.resume(throwing: error) }
            }
            admissionLock.unlock()
        }
    }

    /// Stops admitting audio but keeps everything already written: an
    /// interrupted or abandoned take can still be uploaded from the spool.
    func cancel() {
        admissionLock.lock()
        if accepting {
            accepting = false
            queue.async { [self] in try? closeFiles() }
        }
        admissionLock.unlock()
    }

    private func process(_ input: AVAudioPCMBuffer) {
        guard failure == nil else { return }
        guard input.format == inputFormat else {
            fail(AudioRecordingError.microphoneUnavailable)
            return
        }
        // Bound both streams to the same admitted input interval. This also avoids
        // converting late driver buffers after the duration cap is reached.
        let remainingInputFrames = maximumInputFrames - inputFrames
        guard remainingInputFrames > 0 else { return }
        input.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(input.frameLength), remainingInputFrames))
        inputFrames += AVAudioFramePosition(input.frameLength)
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            fail(AudioRecordingError.conversionUnavailable)
            return
        }
        // AVAudioConverter's speaker downmix produces silence for discrete
        // interface layouts. Mix every input equally before resampling, while
        // retaining the untouched channels in the original recording.
        let conversionBuffer: AVAudioPCMBuffer
        if input.format.channelCount > 2 {
            guard let mono = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: input.frameLength),
                  let source = input.floatChannelData, let destination = mono.floatChannelData else {
                fail(AudioRecordingError.conversionUnavailable)
                return
            }
            mono.frameLength = input.frameLength
            let count = Int(input.format.channelCount)
            for frame in 0..<Int(input.frameLength) {
                var sample: Float = 0
                for channel in 0..<count { sample += source[channel][frame] / Float(count) }
                destination[0][frame] = sample
            }
            conversionBuffer = mono
        } else {
            conversionBuffer = input
        }
        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !suppliedInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return conversionBuffer
        }
        if status == .error {
            fail(conversionError ?? AudioRecordingError.conversionUnavailable as NSError)
            return
        }
        do {
            try write(output)
            // The original is optional. A format/size/storage problem with
            // it must not interrupt transcription or shrink saved speech.
            do { try writeOriginal(input) } catch { omitOriginal() }
            if unsyncedFrames >= syncFrames {
                try checkpoint()
                unsyncedFrames = 0
            }
        } catch { fail(error) }
    }

    private func flushConverter() throws {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096) else {
            throw AudioRecordingError.conversionUnavailable
        }
        // A bounded flush avoids hanging shutdown on a malfunctioning converter.
        for _ in 0..<8 {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if status == .error { throw conversionError ?? AudioRecordingError.conversionUnavailable as NSError }
            try write(output)
            if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { return }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0], let file else { return }
        // The controller stops the microphone at the limit, but its timer can
        // run one callback late. Keep the take within the server's strict limit.
        let remainingFrames = maximumFrames - frames
        guard remainingFrames > 0 else { return }
        buffer.frameLength = min(buffer.frameLength, AVAudioFrameCount(remainingFrames))
        let data = Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let offset = UInt64(frames) * 4
        do { try file.write(contentsOf: data) }
        catch {
            // ENOSPC can arrive after a partial write. Drop the optional copy
            // for space, and retry the same bytes at the same offset once.
            let storageError = error as NSError
            guard originalFile != nil,
                  (storageError.domain == NSPOSIXErrorDomain && storageError.code == Int(ENOSPC))
                    || (storageError.domain == NSCocoaErrorDomain && storageError.code == CocoaError.fileWriteOutOfSpace.rawValue)
            else { throw error }
            omitOriginal()
            try file.seek(toOffset: offset)
            try file.write(contentsOf: data)
        }
        spool.appended(inference: data.count)
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            let magnitude = sample.isFinite ? abs(sample) : 0
            peak = max(peak, magnitude)
            // Sanitize only the measurement; the PCM written above is untouched.
            let measured = Double(min(1, magnitude))
            meterSumSquares += measured * measured
            meterFrames += 1
            if meterFrames == meterWindowFrames {
                let rms = sqrt(meterSumSquares / Double(meterFrames))
                onLevel(meter.update(rms: rms, frameCount: meterFrames, sampleRate: format.sampleRate))
                meterSumSquares = 0
                meterFrames = 0
            }
        }
        frames += AVAudioFramePosition(buffer.frameLength)
        unsyncedFrames += AVAudioFramePosition(buffer.frameLength)
    }

    private func checkpoint() throws {
        if let file { try RecordingSpool.fullSync(file.fileDescriptor) }
        if let originalFile {
            do { try RecordingSpool.fullSync(originalFile.fileDescriptor) } catch { omitOriginal() }
        }
    }

    private func omitOriginal() {
        spool.omitOriginal()
        try? originalFile?.close()
        originalFile = nil
        try? FileManager.default.removeItem(at: spool.originalURL)
    }

    private func writeOriginal(_ buffer: AVAudioPCMBuffer) throws {
        guard let originalFile, let samples = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let bytes = Int64(frameCount * channels * MemoryLayout<Float>.size)
        guard bytes <= OriginalAudioPolicy.maximumBytes - originalBytes else { omitOriginal(); return }
        let data: Data
        if buffer.format.isInterleaved || channels == 1 {
            data = Data(bytes: samples[0], count: frameCount * channels * MemoryLayout<Float>.size)
        } else {
            // The input unit supplies planar buffers. The upload format is packed
            // frame-by-frame, preserving every original channel sample.
            var interleaved = [Float](repeating: 0, count: frameCount * channels)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    interleaved[frame * channels + channel] = samples[channel][frame]
                }
            }
            data = interleaved.withUnsafeBytes { Data($0) }
        }
        try originalFile.write(contentsOf: data)
        originalBytes += bytes
        spool.appended(original: data.count)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onError(error.localizedDescription)
    }

    /// Writer queue only. Everything written so far stays in the spool.
    private func closeFiles() throws {
        defer { spool.finish() }
        // Even after a sync error, close both descriptors and publish the
        // prefix that the filesystem accepted. Never report success first.
        let syncResult = Result { try checkpoint() }
        let closeResult = Result { try file?.close() }
        do { try originalFile?.close() } catch { omitOriginal() }
        originalFile = nil
        file = nil
        try syncResult.get()
        _ = try closeResult.get()
    }
}
