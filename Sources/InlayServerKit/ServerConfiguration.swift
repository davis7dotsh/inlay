import Foundation

public struct ServerConfiguration: Sendable {
    public var host: String
    public var port: Int
    public var dataDirectory: URL
    public var token: String?
    public var development: Bool
    public var inference: InferenceConfiguration

    public init(host: String = "127.0.0.1", port: Int = 8391, dataDirectory: URL,
                token: String? = nil, development: Bool = false, inference: InferenceConfiguration) throws {
        guard (1...65535).contains(port) else { throw ServerConfigurationError.invalid("Port must be between 1 and 65535.") }
        let loopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        if !loopback, (token?.utf8.count ?? 0) < 32 {
            throw ServerConfigurationError.invalid("Listening beyond localhost requires a token file containing at least 32 characters. Use HTTPS or a private encrypted network for remote connections.")
        }
        if let token, token.contains(where: { $0.isWhitespace }) || token.isEmpty {
            throw ServerConfigurationError.invalid("The server token must be nonempty and contain no whitespace.")
        }
        self.host = host
        self.port = port
        self.dataDirectory = dataDirectory.standardizedFileURL
        self.token = token
        self.development = development
        self.inference = inference
    }

    public static func parse(arguments: [String] = Array(CommandLine.arguments.dropFirst()),
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var options: [String: String] = [:]
        var development = environment["INLAY_DEV"] == "1"
        let names: Set<String> = ["host", "port", "data-dir", "token-file", "speech-helper", "speech-model", "vad-model", "proof-helper", "proof-model"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--dev" { development = true; index += 1; continue }
            guard argument.hasPrefix("--"), names.contains(String(argument.dropFirst(2))), index + 1 < arguments.count else {
                throw ServerConfigurationError.invalid("Unknown or incomplete argument: \(argument). Use --help for usage.")
            }
            options[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        func value(_ option: String, _ variable: String) -> String? { options[option] ?? environment[variable] }
        func path(_ option: String, _ variable: String) throws -> URL {
            guard let value = value(option, variable), !value.isEmpty else {
                throw ServerConfigurationError.invalid("Configure --\(option) or \(variable).")
            }
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
        }
        let rawPort = value("port", "INLAY_SERVER_PORT") ?? "8391"
        guard let port = Int(rawPort) else { throw ServerConfigurationError.invalid("Invalid port: \(rawPort)") }
        let token: String?
        if let tokenFile = value("token-file", "INLAY_SERVER_TOKEN_FILE") {
            let url = URL(fileURLWithPath: NSString(string: tokenFile).expandingTildeInPath)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else {
                throw ServerConfigurationError.invalid("The token file must contain at most 4096 bytes of UTF-8 text.")
            }
            token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else { token = nil }
        return try Self(host: value("host", "INLAY_SERVER_HOST") ?? "127.0.0.1", port: port,
                        dataDirectory: path("data-dir", "INLAY_SERVER_DATA_DIR"), token: token,
                        development: development,
                        inference: InferenceConfiguration(speechHelper: path("speech-helper", "INLAY_ENGINE_PATH"),
                            speechModel: path("speech-model", "INLAY_SPEECH_MODEL"), vadModel: path("vad-model", "INLAY_VAD_PATH"),
                            proofHelper: path("proof-helper", "INLAY_TEXT_ENGINE_PATH"), proofModel: path("proof-model", "INLAY_TEXT_MODEL")))
    }

    public static let usage = """
    Inlay server — independent dictation service
    inlay-server --data-dir PATH --speech-helper PATH --speech-model PATH --vad-model PATH \
      --proof-helper PATH --proof-model PATH [--host 127.0.0.1] [--port 8391] [--token-file PATH] [--dev]

    macOS uses Whisper/Metal and Qwen/MLX. Linux uses Whisper/CUDA and Qwen/llama.cpp.
    Models must already exist. The server never downloads or imports personal data automatically.
    Use persistent storage for --data-dir. Remote bindings require --token-file.
    """
}

public enum ServerConfigurationError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
