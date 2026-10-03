import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// JSON-lines transport for the native helpers. Each helper remains warm between
/// requests; cancellation or a protocol failure replaces that helper process.
actor HelperProcess {
    struct Response: Decodable, Sendable {
        let type: String
        var id: String?
        var message: String?
        var text: String?
        var duration: Double?
        var elapsed: Double?
        var language: String?
        var value: Double?
        var engineVersion: String?
        var includedTerms: [String]?
        var omittedTerms: [String]?
        var tokenCount: Int?
        var tokenBudget: Int?
    }

    struct Snapshot: Sendable {
        let loaded: Bool
        let loading: Bool
        let busy: Bool
        let engineVersion: String?
    }

    private let executable: URL
    private let arguments: [String]
    private let requiredFiles: [URL]
    private let name: String
    private let loadTimeout: Double
    private let lineLimit: Int
    private var process: Process?
    private var input: FileHandle?
    private var generation = UUID()
    private var loaded = false
    private var engineVersion: String?
    private var loadingTask: Task<Void, Error>?
    private var loadingID: UUID?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var resultContinuation: CheckedContinuation<Response, Error>?
    private var requestID: String?
    private var operationID: UUID?
    private var progress: (@Sendable (Double) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutID: UUID?

    init(name: String, executable: URL, arguments: [String], requiredFiles: [URL],
         loadTimeout: Double, lineLimit: Int) {
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.requiredFiles = requiredFiles
        self.loadTimeout = loadTimeout
        self.lineLimit = lineLimit
    }

    func snapshot() -> Snapshot {
        Snapshot(loaded: loaded && process?.isRunning == true, loading: loadingTask != nil,
                 busy: operationID != nil, engineVersion: engineVersion)
    }

    func ensureLoaded() async throws {
        try Task.checkCancellation()
        if loaded, process?.isRunning == true { return }
        if let loadingTask {
            try await loadingTask.value
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        loadingID = id
        let task = Task { try await self.start() }
        loadingTask = task
        defer {
            if loadingID == id {
                loadingID = nil
                loadingTask = nil
            }
        }
        try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelLoading(id) }
        }
    }

    func request(_ data: Data, id: String, timeout: Double,
                 onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard operationID == nil else { throw InferenceError.busy }
        let operation = UUID()
        operationID = operation
        defer { if operationID == operation { operationID = nil } }
        return try await withTaskCancellationHandler {
            try await ensureLoaded()
            try Task.checkCancellation()
            guard operationID == operation, let input, process?.isRunning == true else {
                throw InferenceError.cancelled
            }
            requestID = id
            progress = onProgress
            var line = data
            line.append(0x0a)
            let payload = line
            let current = generation
            return try await withCheckedThrowingContinuation { continuation in
                resultContinuation = continuation
                setTimeout(seconds: timeout, message: "\(name) inference timed out.")
                // A stopped reader must not block the actor responsible for its deadline.
                DispatchQueue(label: "app.inlay.server.helper-input").async {
                    do { try input.write(contentsOf: payload) }
                    catch {
                        Task { await self.transportFailed(current, message: "Could not write to \(self.name).") }
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelOperation(operation) }
        }
    }

    /// An idle warm helper is deliberately preserved when a take is cancelled.
    func cancel() {
        if operationID != nil || loadingTask != nil || readyContinuation != nil {
            reset(throwing: InferenceError.cancelled)
        }
    }

    func shutdown() { reset(throwing: InferenceError.cancelled) }

    private func cancelOperation(_ id: UUID) {
        guard operationID == id else { return }
        reset(throwing: InferenceError.cancelled)
    }

    private func cancelLoading(_ id: UUID) {
        guard loadingID == id else { return }
        reset(throwing: InferenceError.cancelled)
    }

    private func start() async throws {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw InferenceError.unavailable("\(name) executable is missing: \(executable.path)")
        }
        guard requiredFiles.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw InferenceError.unavailable("\(name) model files are missing or unreadable.")
        }
        // A child exiting while a request is being written must yield EPIPE,
        // never terminate the independent server.
        signal(SIGPIPE, SIG_IGN)
        let current = UUID()
        generation = current
        loaded = false
        engineVersion = nil
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        self.process = child
        input = stdin.fileHandleForWriting
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            do {
                try child.run()
                readLines(stdout.fileHandleForReading, generation: current)
                drainDiagnostics(stderr.fileHandleForReading)
                setTimeout(seconds: loadTimeout, message: "\(name) model loading timed out.")
            } catch {
                reset(throwing: InferenceError.unavailable("Could not launch \(name): \(error.localizedDescription)"))
            }
        }
    }

    private func readLines(_ handle: FileHandle, generation current: UUID) {
        let limit = lineLimit
        DispatchQueue(label: "app.inlay.server.helper-output", qos: .userInitiated).async { [weak self] in
            defer { try? handle.close() }
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = bytes.withUnsafeMutableBytes { storage in
                    read(handle.fileDescriptor, storage.baseAddress, storage.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    Task { await self?.transportFailed(current, message: "Native helper closed its output.") }
                    return
                }
                buffer.append(contentsOf: bytes.prefix(count))
                while let newline = buffer.firstIndex(of: 0x0a) {
                    guard buffer.distance(from: buffer.startIndex, to: newline) <= limit else {
                        Task { await self?.transportFailed(current, message: "Native helper response exceeded its size limit.") }
                        return
                    }
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    // Backpressure preserves JSON-lines order without accumulating
                    // an unbounded number of actor tasks from a noisy subprocess.
                    let delivered = DispatchSemaphore(value: 0)
                    Task {
                        await self?.receive(line, generation: current)
                        delivered.signal()
                    }
                    delivered.wait()
                }
                if buffer.count > limit {
                    Task { await self?.transportFailed(current, message: "Native helper response exceeded its size limit.") }
                    return
                }
            }
        }
    }

    private func drainDiagnostics(_ handle: FileHandle) {
        DispatchQueue(label: "app.inlay.server.helper-diagnostics", qos: .utility).async {
            defer { try? handle.close() }
            // GPU libraries can be verbose. Drain stderr in fixed-size buffers;
            // neither transcript content nor unbounded diagnostics enter server logs.
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = bytes.withUnsafeMutableBytes { read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { return }
            }
        }
    }

    private func receive(_ data: Data, generation current: UUID) {
        guard generation == current else { return }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            reset(throwing: InferenceError.invalidResponse("\(name) returned invalid JSON."))
            return
        }
        switch response.type {
        case "ready":
            guard let continuation = readyContinuation, !loaded else { return }
            readyContinuation = nil
            clearTimeout()
            loaded = true
            engineVersion = response.engineVersion
            continuation.resume()
        case "progress":
            guard response.id == requestID, let value = response.value, value.isFinite else { return }
            progress?(min(1, max(0, value)))
        case "result":
            guard response.id == requestID, let continuation = resultContinuation else { return }
            resultContinuation = nil
            requestID = nil
            progress = nil
            clearTimeout()
            continuation.resume(returning: response)
        case "error":
            if let id = response.id, id != requestID { return }
            reset(throwing: InferenceError.unavailable(response.message ?? "\(name) inference failed."))
        default:
            reset(throwing: InferenceError.invalidResponse("\(name) returned an unknown event."))
        }
    }

    private func transportFailed(_ current: UUID, message: String) {
        guard generation == current else { return }
        reset(throwing: InferenceError.unavailable(message))
    }

    private func setTimeout(seconds: Double, message: String) {
        clearTimeout()
        let id = UUID()
        timeoutID = id
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self?.timedOut(id, message: message)
        }
    }

    private func timedOut(_ id: UUID, message: String) {
        guard timeoutID == id else { return }
        reset(throwing: InferenceError.timeout(message))
    }

    private func clearTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
        timeoutID = nil
    }

    private func reset(throwing error: any Error) {
        generation = UUID()
        loaded = false
        engineVersion = nil
        clearTimeout()
        let ready = readyContinuation
        readyContinuation = nil
        let result = resultContinuation
        resultContinuation = nil
        requestID = nil
        operationID = nil
        progress = nil
        loadingTask?.cancel()
        loadingTask = nil
        loadingID = nil
        try? input?.close()
        input = nil
        let old = process
        process = nil
        if let old, old.isRunning {
            old.terminate()
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        ready?.resume(throwing: error)
        result?.resume(throwing: error)
    }
}
