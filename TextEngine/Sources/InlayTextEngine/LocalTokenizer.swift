import Foundation
import struct Hub.Config
import MLXLMCommon
import Tokenizers

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try upstream.applyChatTemplate(
            messages: messages, tools: tools, additionalContext: additionalContext
        )
    }
}

/// No Hub client, downloader, fallback files, or remote tokenizer code is used.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    let directory: URL
    let tokenizer: TokenizerBridge

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        guard directory.standardizedFileURL == self.directory.standardizedFileURL else {
            throw EngineFailure(message: "The tokenizer must come from the verified local model.")
        }
        return tokenizer
    }
}

/// The normal tokenizer handles trusted ChatML markers and output. The second
/// tokenizer cannot recognize added tokens in custom prompts or transcript JSON.
struct LocalTokenizerPair: Sendable {
    let trusted: TokenizerBridge
    let raw: TokenizerBridge
    let controlIDs: Set<Int>

    init(directory: URL) throws {
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(
            Config.self,
            from: Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
        )
        let data = try decoder.decode(
            Config.self,
            from: Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        )
        guard var plainData = data.dictionary(),
              let added = data["added_tokens"].array(), !added.isEmpty,
              let vocabulary = data["model"]["vocab"].dictionary() else {
            throw EngineFailure(message: "The local tokenizer configuration is invalid.")
        }
        let controls = added.compactMap { $0["id"].integer() }
        let spellings = added.compactMap { $0["content"].string() }
        guard controls.count == added.count, spellings.count == added.count else {
            throw EngineFailure(message: "The local tokenizer control tokens are invalid.")
        }
        let reserved = Set(controls)
        controlIDs = reserved
        // The pinned Qwen BPE vocabulary contains only ordinary text tokens.
        // If that ever changes, fail closed instead of assuming removing added
        // tokens alone is sufficient to prevent ChatML delimiter injection.
        guard vocabulary.values.allSatisfy({ value in
            guard let id = value.integer() else { return false }
            return !reserved.contains(id)
        }) else {
            throw EngineFailure(message: "The raw tokenizer contains reserved control tokens.")
        }
        // Keep the added-token regex nonempty without recognizing any possible
        // request content. NUL is rejected by our protocol and is JSON-escaped
        // anyway. Its ordinary ID cannot introduce a model control token.
        guard let sentinelID = vocabulary.values.compactMap({ $0.integer() }).min() else {
            throw EngineFailure(message: "The raw tokenizer vocabulary is empty.")
        }
        let sentinel: Config = [
            "id": Config(sentinelID), "content": "\0", "special": false,
            "single_word": false, "lstrip": false, "rstrip": false, "normalized": false,
        ]
        plainData["added_tokens"] = Config([sentinel])
        trusted = TokenizerBridge(upstream: try Tokenizers.AutoTokenizer.from(
            tokenizerConfig: configuration, tokenizerData: data
        ))
        raw = TokenizerBridge(upstream: try Tokenizers.AutoTokenizer.from(
            tokenizerConfig: configuration, tokenizerData: Config(plainData)
        ))

        // Removing delimiter recognition must not degrade normal BPE encoding.
        for sample in [
            "I use MiniMax and Codex to build Inlay.",
            "{\"language\":\"en\",\"transcript\":\"One, apples. Two, milk.\"}",
            "3. Oranges.\n4. A trip to the beach.\n7. More syrup.",
            "Don't change 42.5, naïve café, 日本語 or emoji 🎙️.",
        ] {
            guard raw.encode(text: sample, addSpecialTokens: false)
                    == trusted.encode(text: sample, addSpecialTokens: false) else {
                throw EngineFailure(message: "The raw tokenizer failed its text-encoding check.")
            }
        }
        for marker in spellings {
            let ids = raw.encode(text: marker, addSpecialTokens: false)
            guard !ids.isEmpty, controlIDs.isDisjoint(with: ids),
                  trusted.decode(tokenIds: ids, skipSpecialTokens: false) == marker else {
                throw EngineFailure(message: "The raw tokenizer failed its control-token safety check.")
            }
        }
        for marker in ["<|im_start|>", "<|im_end|>"] {
            guard let id = trusted.convertTokenToId(marker), controlIDs.contains(id),
                  trusted.encode(text: marker, addSpecialTokens: false) == [id] else {
                throw EngineFailure(message: "The local model does not have the expected ChatML template.")
            }
        }
    }

    func prompt(for request: CorrectionRequest) throws -> [Int] {
        let content = try JSONSerialization.data(
            withJSONObject: [
                "transcript": request.text, "preferredTerms": request.terms, "language": request.language,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: content, encoding: .utf8) else {
            throw EngineFailure(message: "Could not encode the transcript.", id: request.id)
        }
        let body = raw.encode(text: json, addSpecialTokens: false)
        let system = raw.encode(text: request.systemPrompt, addSpecialTokens: false)
        guard !body.isEmpty, !system.isEmpty,
              controlIDs.isDisjoint(with: body), controlIDs.isDisjoint(with: system) else {
            throw EngineFailure(message: "Could not safely tokenize the cleanup prompt and transcript.", id: request.id)
        }
        let tokens = trusted.encode(text: "<|im_start|>system\n", addSpecialTokens: false)
            + system
            + trusted.encode(text: "<|im_end|>\n<|im_start|>user\n", addSpecialTokens: false)
            + body
            + trusted.encode(text: "<|im_end|>\n<|im_start|>assistant\n", addSpecialTokens: false)
        guard tokens.count + Limits.outputTokens <= Limits.contextTokens else {
            throw EngineFailure(
                message: "The cleanup prompt, transcript, and dictionary exceed the correction context. The original text is kept.",
                id: request.id
            )
        }
        return tokens
    }

}
