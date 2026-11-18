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
    private var tokenizationSeconds: Double?
    private var inputTokens: Int?
    private var firstTokenSeconds: Double?
    private var lastTokenSeconds: Double?
    private var outputTokens = 0

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
            writer.emit(.init(
                type: "error", id: id,
                message: "Local correction exceeded its time limit. The original text is kept.",
                metrics: self.metricsLocked()
            ))
            _exit(1)
        }
        timer.resume()
        backstop.resume()
    }

    var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000 }
    var expired: Bool { elapsed >= Limits.inferenceSeconds }

    func tokenized(_ count: Int) {
        lock.lock()
        defer { lock.unlock() }
        tokenizationSeconds = elapsed
        inputTokens = count
    }

    func receivedToken() {
        lock.lock()
        defer { lock.unlock() }
        let now = elapsed
        if firstTokenSeconds == nil { firstTokenSeconds = now }
        lastTokenSeconds = now
        outputTokens += 1
    }

    var metrics: InferenceMetrics {
        lock.lock()
        defer { lock.unlock() }
        return metricsLocked()
    }

    private func metricsLocked() -> InferenceMetrics {
        // Exclude the first token from decoding throughput: its wait includes
        // tokenization, model admission and prefill. One token has no rate.
        let generationSeconds = firstTokenSeconds.flatMap { first in
            lastTokenSeconds.map { $0 - first }
        }
        let rate = generationSeconds.flatMap { seconds in
            outputTokens > 1 && seconds > 0 ? Double(outputTokens - 1) / seconds : nil
        }
        return .init(elapsedSeconds: elapsed, tokenizationSeconds: tokenizationSeconds,
                     inputTokens: inputTokens, timeToFirstTokenSeconds: firstTokenSeconds,
                     outputTokens: outputTokens, generationSeconds: generationSeconds,
                     generationTokensPerSecond: rate)
    }

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
    private let residency: WiredMemoryTicket

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
        // Model ownership includes residency: a live process alone does not
        // prevent idle weights from being paged out. Bound the request to this
        // model plus modest scratch space, never the whole recommended set.
        let budget = min(
            Memory.activeMemory + 256 * 1024 * 1024,
            GPU.maxRecommendedWorkingSetBytes() ?? 0,
            Int(ProcessInfo.processInfo.physicalMemory / 4)
        )
        residency = WiredMemoryTicket(size: budget, policy: WiredMaxPolicy(), kind: .active)
        _ = await residency.start()
    }

    func releaseResidency() async {
        _ = await residency.end()
    }

    func prepare() async throws {
        // Compile/evaluate the real model before advertising readiness. This
        // throwaway KV cache contains only fixed text and is never reused.
        let request = CorrectionRequest(
            id: "startup", text: "Ready.", language: "en", terms: [],
            systemPrompt: "Return only the cleaned transcript."
        )
        let prompt = try tokenizers.prompt(for: request)
        try await container.perform(values: prompt) { context, prompt in
            let (events, task) = try generateTokensTask(
                input: LMInput(tokens: MLXArray(prompt)), cache: nil,
                parameters: GenerateParameters(maxTokens: 1, temperature: 0, prefillStepSize: 512),
                context: context
            )
            var receivedToken = false
            for await event in events {
                if case .token = event { receivedToken = true }
            }
            await task.value
            guard receivedToken else {
                throw EngineFailure(message: "The local text model could not prepare for correction.")
            }
        }
    }

    func correct(_ request: CorrectionRequest, writer: ProtocolWriter) async -> EngineEvent {
        let deadline = InferenceDeadline(id: request.id, writer: writer)
        defer { deadline.finish() }
        do {
            let prompt = try tokenizers.prompt(for: request)
            deadline.tokenized(prompt.count)
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
                            deadline.receivedToken()
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
                return .init(type: "result", id: request.id, text: text, elapsed: deadline.elapsed,
                             metrics: deadline.metrics)
            case .failure(let error):
                return .init(type: "error", id: request.id, message: error.message, metrics: deadline.metrics)
            }
        } catch let failure as EngineFailure {
            return .init(type: "error", id: request.id, message: failure.message, metrics: deadline.metrics)
        } catch {
            return .init(type: "error", id: request.id, message: "The local text model could not correct this transcript.",
                         metrics: deadline.metrics)
        }
    }
}

private func timeout(_ id: String) -> EngineFailure {
    .init(message: "Local correction exceeded its time limit. The original text is kept.", id: id)
}
