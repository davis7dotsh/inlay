import AVFoundation
import CoreAudio
import Foundation

/// The only state shared with the audio callback. Closing admission is
/// synchronous, even while a driver is still servicing start() on its queue.
final class AudioCaptureRequest: @unchecked Sendable {
    let id = UUID()
    let onChunk: (@Sendable (CapturedAudioChunk) -> Void)?
    private enum State { case open, released, cancelled }
    private let lock = NSLock()
    private var state: State = .open

    init(onChunk: (@Sendable (CapturedAudioChunk) -> Void)? = nil) {
        self.onChunk = onChunk
    }

    var acceptsAudio: Bool { lock.withLock { state == .open } }
    var isReleased: Bool { lock.withLock { state == .released } }
    var isCancelled: Bool { lock.withLock { state == .cancelled } }

    func release() {
        lock.withLock { if state == .open { state = .released } }
    }

    func cancel() { lock.withLock { state = .cancelled } }

    func requireOpen() throws {
        try lock.withLock {
            switch state {
            case .open: break
            case .released: throw AudioRecordingError.noAudio
            case .cancelled: throw AudioRecordingError.cancelled
            }
        }
    }
}

/// Implementations are created, used, and destroyed on one capture queue.
/// Tests provide a fake implementation; they never construct an audio engine.
protocol AudioCaptureHardware: AnyObject {
    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) throws
    func stop() -> RecordingWriter?
    func cancel()
}

/// Serializes hardware work without occupying MainActor. A captured request ID
/// protects a new take from old teardown and notification work.
final class AudioCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.inlay.audio-capture", qos: .userInitiated)
    private let makeHardware: @Sendable (DispatchQueue) -> AudioCaptureHardware
    private var hardware: AudioCaptureHardware?
    private var requestID: UUID?

    init(makeHardware: @escaping @Sendable (DispatchQueue) -> AudioCaptureHardware) {
        self.makeHardware = makeHardware
    }

    func start(request: AudioCaptureRequest, deviceID: AudioDeviceID?, preserveOriginalAudio: Bool = false,
               onLevel: @escaping @Sendable (Float) -> Void,
               onInterruption: @escaping @Sendable (String) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try request.requireOpen()
                        guard hardware == nil else { throw AudioRecordingError.alreadyRecording }
                        let capture = makeHardware(queue)
                        hardware = capture
                        requestID = request.id
                        do {
                            try capture.start(request: request, deviceID: deviceID,
                                              preserveOriginalAudio: preserveOriginalAudio,
                                              onLevel: onLevel, onInterruption: onInterruption)
                            guard !request.isCancelled else { throw AudioRecordingError.cancelled }
                            continuation.resume()
                        } catch {
                            if !request.isReleased { request.cancel() }
                            capture.cancel()
                            hardware = nil
                            requestID = nil
                            continuation.resume(throwing: error)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            request.cancel()
            self.cancel(request: request)
        }
    }

    func stop(request: AudioCaptureRequest) async throws -> CapturedAudio {
        request.release()
        let writer: RecordingWriter? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard requestID == request.id else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let writer = hardware?.stop()
                    hardware = nil
                    requestID = nil
                    continuation.resume(returning: writer)
                }
            }
        } onCancel: { request.cancel() }
        guard let writer else {
            throw request.isCancelled ? AudioRecordingError.cancelled : AudioRecordingError.noAudio
        }
        guard !request.isCancelled, !Task.isCancelled else {
            writer.cancel()
            throw AudioRecordingError.cancelled
        }
        return try await withTaskCancellationHandler {
            let audio = try await writer.finish()
            guard !request.isCancelled, !Task.isCancelled else {
                audio.cleanup()
                throw AudioRecordingError.cancelled
            }
            return audio
        } onCancel: {
            request.cancel()
            writer.cancel()
        }
    }

    func cancel(request: AudioCaptureRequest) {
        request.cancel()
        queue.async { [self] in
            guard requestID == request.id else { return }
            hardware?.cancel()
            hardware = nil
            requestID = nil
        }
    }
}
