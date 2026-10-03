import Darwin
import Foundation

enum Limits {
    static let requestBytes = 64 * 1024
    static let textBytes = 24 * 1024
    static let systemPromptBytes = 4096
    static let contextTokens = 8192
    static let outputTokens = 2048
    static let inferenceSeconds: Double = 15
    static let engineVersion = "mlx-swift-0.31.4-lm-3.31.4-inlay2"
}

struct EngineFailure: Error, Sendable {
    let message: String
    var id: String? = nil
}

struct CorrectionRequest: Sendable {
    let id: String
    let text: String
    let language: String
    let terms: [String]
    let systemPrompt: String

    static func parse(_ data: Data) -> Result<Self, EngineFailure> {
        guard String(data: data, encoding: .utf8) != nil,
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .failure(.init(message: "The correction request is invalid JSON."))
        }
        guard let object = value as? [String: Any], string(object["type"]) == "correct" else {
            return .failure(.init(message: "Expected a correction request."))
        }
        guard let id = string(object["id"]), !id.isEmpty, id.utf8.count <= 256 else {
            return .failure(.init(message: "A correction request needs a valid id."))
        }
        guard let text = string(object["text"]), !trim(text).isEmpty,
              text.utf8.count <= Limits.textBytes else {
            return .failure(.init(message: "The transcript is empty or too long for local correction.", id: id))
        }
        guard let language = string(object["language"]), !language.isEmpty,
              language.utf8.count <= 32 else {
            return .failure(.init(message: "A correction request needs a valid language.", id: id))
        }
        guard let systemPrompt = string(object["systemPrompt"]), !trim(systemPrompt).isEmpty,
              systemPrompt.utf8.count <= Limits.systemPromptBytes else {
            return .failure(.init(message: "The cleanup system prompt must be nonempty and fit within 4 KB.", id: id))
        }
        guard let values = object["terms"] as? [Any], values.count <= 256 else {
            return .failure(.init(message: "Preferred terms must be a list of at most 256 words or phrases.", id: id))
        }
        var terms: [String] = []
        var bytes = 0
        for value in values {
            guard let term = value as? String else {
                return .failure(.init(message: "Preferred terms must be strings.", id: id))
            }
            bytes += term.utf8.count
            guard !term.isEmpty, !term.contains("\0"), term.utf8.count <= 256, bytes <= 16384 else {
                return .failure(.init(message: "Preferred terms exceed the local correction limit.", id: id))
            }
            terms.append(term)
        }
        return .success(.init(id: id, text: text, language: language, terms: terms, systemPrompt: systemPrompt))
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.contains("\0") else { return nil }
        return text
    }
}

func trim(_ text: String) -> String {
    text.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t"))
}

struct EngineEvent: Encodable, Sendable {
    let type: String
    var id: String? = nil
    var message: String? = nil
    var text: String? = nil
    var elapsed: Double? = nil
    var engineVersion: String? = nil
}

/// All output is protocol JSON. Never print prompts, transcripts, or upstream errors.
final class ProtocolWriter: @unchecked Sendable {
    private let lock = NSLock()

    func emit(_ event: EngineEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard var data = try? JSONEncoder().encode(event) else { _exit(1) }
        data.append(0x0a)
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { _exit(0) }
                offset += written
            }
        }
    }

    func error(_ failure: EngineFailure) {
        emit(.init(type: "error", id: failure.id, message: failure.message))
    }
}

/// Reads at most one bounded request at a time, without blocking Swift's executor.
final class BoundedLineReader: @unchecked Sendable {
    enum Input: Sendable {
        case line(Data)
        case end
        case oversized
        case failed
    }

    private let queue = DispatchQueue(label: "app.inlay.text-input", qos: .userInitiated)
    // Accessed only by queue.
    private var buffer = [UInt8](repeating: 0, count: 4096)
    private var available = 0
    private var cursor = 0
    private var ended = false

    func next() async -> Input {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readLine()) }
        }
    }

    private func readLine() -> Input {
        var line = Data()
        while true {
            if cursor == available {
                if ended { return line.isEmpty ? .end : .line(line) }
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { return .failed }
                if count == 0 {
                    ended = true
                    return line.isEmpty ? .end : .line(line)
                }
                available = count
                cursor = 0
            }
            let byte = buffer[cursor]
            cursor += 1
            if byte == 0x0a { return .line(line) }
            guard line.count < Limits.requestBytes else { return .oversized }
            line.append(byte)
        }
    }
}

/// The helper must not outlive Inlay, even if another process retains stdin.
final class ParentWatcher {
    private let process: any DispatchSourceProcess
    private let fallback: any DispatchSourceTimer

    init() {
        let parent = getppid()
        guard parent > 1 else { _exit(0) }
        let queue = DispatchQueue(label: "app.inlay.text-parent", qos: .utility)
        process = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
        process.setEventHandler { _exit(0) }
        process.resume()
        fallback = DispatchSource.makeTimerSource(queue: queue)
        fallback.schedule(deadline: .now() + 1, repeating: 1)
        fallback.setEventHandler {
            if getppid() != parent { _exit(0) }
        }
        fallback.resume()
        if getppid() != parent { _exit(0) }
    }

    deinit {
        process.cancel()
        fallback.cancel()
    }
}
