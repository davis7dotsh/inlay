import Darwin
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import InlayCore

/// Cooperative cancellation at 15 seconds; a process backstop bounds a stalled
/// synchronous Metal prefill, which Swift task cancellation cannot interrupt.
private final class InferenceDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: any DispatchSourceTimer
    private let backstop: any DispatchSourceTimer
    private let started = DispatchTime.now().uptimeNanoseconds
    private var generationTask: Task<Void, Never>?
    private var finished = false

    init(id: String, writer: ProtocolWriter) {
        let queue = DispatchQueue(label: "app.inlay.text-deadline", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        backstop = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Limits.inferenceSeconds)
        backstop.schedule(deadline: .now() + Limits.inferenceSeconds + 2)
        timer.setEventHandler { [weak self] in self?.cancelGeneration() }
        backstop.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard !self.finished else { self.lock.unlock(); return }
            // Hold the lock until exit so the main request cannot emit a second
            // response if Metal completes concurrently with the hard deadline.
            writer.error(.init(
                message: "Local correction exceeded its time limit. The original text is kept.", id: id
            ))
            _exit(1)
        }
        timer.resume()
        backstop.resume()
    }

    var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
    var expired: Bool { elapsed >= Limits.inferenceSeconds }

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        generationTask = task
        let shouldCancel = finished || expired
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func finish() {
        lock.lock()
        finished = true
        generationTask = nil
        lock.unlock()
        timer.cancel()
        backstop.cancel()
    }

    private func cancelGeneration() {
        lock.lock()
        let task = finished ? nil : generationTask
        lock.unlock()
        task?.cancel()
    }

    deinit {
        timer.cancel()
        backstop.cancel()
    }
}

struct CorrectionEngine: Sendable {
    private let container: ModelContainer
    private let tokenizers: LocalTokenizerPair

    init(directory: URL) async throws {
        guard case .success = TextModel.qwen.verify(directory) else {
            throw EngineFailure(message: "Download the verified local text model first.")
        }
        let pair = try LocalTokenizerPair(directory: directory)
        // Keep cached scratch buffers modest when the small helper stays warm.
        Memory.cacheLimit = 64 * 1024 * 1024
        container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: LocalTokenizerLoader(directory: directory, tokenizer: pair.trusted)
        )
        tokenizers = pair
    }

    func correct(_ request: CorrectionRequest, writer: ProtocolWriter) async -> EngineEvent {
        let deadline = InferenceDeadline(id: request.id, writer: writer)
        defer { deadline.finish() }
        do {
            let prompt = try tokenizers.prompt(for: request)
            guard !deadline.expired else { throw timeout(request.id) }
            let result = try await container.perform(values: prompt) { context, prompt in
                let input = LMInput(tokens: MLXArray(prompt))
                let parameters = GenerateParameters(
                    maxTokens: Limits.outputTokens, temperature: 0, prefillStepSize: 512
                )
                let (events, task) = try generateTokensTask(
                    input: input, cache: nil, parameters: parameters, context: context
                )
                deadline.attach(task)
                return await withTaskCancellationHandler {
                    var tokens: [Int] = []
                    var completion: GenerateCompletionInfo?
                    var failure: EngineFailure?
                    for await event in events {
                        if Task.isCancelled || deadline.expired {
                            failure = timeout(request.id)
                            task.cancel()
                            break
                        }
                        switch event {
                        case .token(let token):
                            tokens.append(token)
                            if tokens.count % 32 == 0,
                               context.tokenizer.decode(tokenIds: tokens).utf8.count > Limits.textBytes {
                                failure = .init(
                                    message: "The text model returned too much text. The original transcript is kept.",
                                    id: request.id
                                )
                                task.cancel()
                            }
                        case .info(let info):
                            completion = info
                        }
                        if failure != nil { break }
                    }
                    // Do not release the model/cache while upstream Metal work
                    // from an early-ended AsyncStream is still finishing.
                    await task.value
                    if Task.isCancelled || deadline.expired {
                        return Result<String, EngineFailure>.failure(timeout(request.id))
                    }
                    if let failure { return .failure(failure) }
                    guard let completion else {
                        return .failure(.init(message: "The text model did not complete this correction.", id: request.id))
                    }
                    switch completion.stopReason {
                    case .length:
                        return .failure(.init(
                            message: "The correction reached its output limit. The original transcript is kept.",
                            id: request.id
                        ))
                    case .cancelled:
                        return .failure(timeout(request.id))
                    case .stop:
                        break
                    }
                    let output = trim(context.tokenizer.decode(tokenIds: tokens))
                    guard !output.isEmpty else {
                        return .failure(.init(message: "The text model returned no correction.", id: request.id))
                    }
                    guard output.utf8.count <= Limits.textBytes else {
                        return .failure(.init(
                            message: "The text model returned too much text. The original transcript is kept.",
                            id: request.id
                        ))
                    }
                    return .success(output)
                } onCancel: {
                    task.cancel()
                }
            }
            guard !deadline.expired else { throw timeout(request.id) }
            switch result {
            case .success(let text):
                return .init(type: "result", id: request.id, text: text, elapsed: deadline.elapsed)
            case .failure(let error):
                return .init(type: "error", id: request.id, message: error.message)
            }
        } catch let failure as EngineFailure {
            return .init(type: "error", id: request.id, message: failure.message)
        } catch {
            return .init(type: "error", id: request.id, message: "The local text model could not correct this transcript.")
        }
    }
}

private func timeout(_ id: String) -> EngineFailure {
    .init(message: "Local correction exceeded its time limit. The original text is kept.", id: id)
}
