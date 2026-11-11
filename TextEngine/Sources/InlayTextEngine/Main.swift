import Darwin
import Foundation

@main
enum InlayTextEngine {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let writer = ProtocolWriter()
        let watcher = ParentWatcher()
        let status = await run(writer: writer)
        withExtendedLifetime(watcher) {}
        exit(status)
    }

    private static func run(writer: ProtocolWriter) async -> Int32 {
        let directory: URL
        switch parseArguments(Array(CommandLine.arguments.dropFirst())) {
        case .success(let url): directory = url
        case .failure(let failure): writer.error(failure); return 1
        }
        let engine: CorrectionEngine
        do {
            engine = try await CorrectionEngine(directory: directory)
        } catch let failure as EngineFailure {
            writer.error(failure)
            return 1
        } catch {
            writer.error(.init(message: "Could not load the local text model."))
            return 1
        }
        writer.emit(.init(type: "ready", engineVersion: Limits.engineVersion))
        let input = BoundedLineReader()
        while true {
            switch await input.next() {
            case .end:
                return 0
            case .oversized:
                writer.error(.init(message: "Correction request exceeds 64 KB."))
                return 1
            case .failed:
                writer.error(.init(message: "Could not read the correction request."))
                return 1
            case .line(let data):
                if data.isEmpty { continue }
                switch CorrectionRequest.parse(data) {
                case .failure(let failure):
                    writer.error(failure)
                case .success(let request):
                    writer.emit(await engine.correct(request, writer: writer))
                }
            }
        }
    }

    private static func parseArguments(_ arguments: [String]) -> Result<URL, EngineFailure> {
        var path: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard index < arguments.count else { return .failure(usage) }
            let value = arguments[index]
            index += 1
            switch argument {
            case "--model":
                path = value
            case "--threads":
                // Accepted for protocol compatibility; MLX schedules GPU work.
                guard let threads = Int(value), (1...32).contains(threads) else {
                    return .failure(.init(message: "The thread count must be between 1 and 32."))
                }
            default:
                return .failure(usage)
            }
        }
        guard let path, !path.isEmpty, !path.contains("\0") else {
            return .failure(.init(message: "Download the local text model first."))
        }
        return .success(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static var usage: EngineFailure {
        .init(message: "Usage: inlay-text-engine --model MODEL_DIRECTORY [--threads N]")
    }
}
