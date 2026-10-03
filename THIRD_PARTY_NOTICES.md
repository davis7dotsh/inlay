# Third-party notices

- **whisper.cpp / ggml**, MIT license, pinned to v1.9.3 (371b5a7561823ab2bb32142d2751e35e7534727b). Source and license: [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp). Linked statically into the native helper. Its bundled nlohmann/json and WAV decoder retain their upstream notices in source.
- **NVIDIA Parakeet TDT 0.6B v3**, CC-BY-4.0 license. [Model card and attribution](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [license](https://creativecommons.org/licenses/by/4.0/), [GGML conversion](https://huggingface.co/ggml-org/parakeet-GGUF). NVIDIA’s weights are converted to FP16 GGML by ggml-org; the source model is otherwise unchanged. Downloaded separately, not committed into this repository. The FP16 model is pinned by revision and SHA-256 in `SpeechModel.swift` and `download-model.sh`.
- **Qwen3-4B-Instruct-2507**, Apache-2.0 license. [Official model card](https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507), [current MLX 4-bit conversion](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/tree/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b). The non-thinking model is downloaded separately, not committed. Revision, byte counts, and SHA-256 values for all six model/tokenizer/configuration files are pinned in `TextModel.swift`; processing metadata identifies the full manifest. Apache-2.0 license text is in `Resources/Qwen-LICENSE.txt`.
- **Silero VAD**, MIT license. [snakers4/silero-vad](https://github.com/snakers4/silero-vad), [GGML conversion](https://huggingface.co/ggml-org/whisper-vad). The small voice-activity model is bundled with the server package; its download is pinned and verified by `download-vad.sh`.
- **JSON for Modern C++** v3.11.2 (speech helper) and v3.11.3 (vendored by MLX Swift), MIT license. [nlohmann/json](https://github.com/nlohmann/json). Upstream license/copyright notices are included in `Resources/JSON-LICENSE.txt` and `Resources/mlx-vendored-LICENSE.txt`.
- **miniaudio / dr_wav**, MIT No Attribution option, copyright 2025 David Reid. [mackron/miniaudio](https://github.com/mackron/miniaudio). Only the WAV decoding component is used; its license is included in the server resources.

## TypeScript server and API bindings

- **Bun 1.4.2**, MIT, embeds its runtime in the compiled server. The exact [upstream license and runtime acknowledgements](https://github.com/oven-sh/bun/blob/bun-v1.4.2/LICENSE.md), including JavaScriptCore/WebKit and linked-library notices, are preserved in `Resources/bun-LICENSE.txt`.
- **Fastify 5.12.4**, MIT; **Ajv 8.20.0** and **ajv-formats 3.0.1**, MIT; **YAML 2.8.1**, ISC. Direct pins are in `Server/package.json`, and installed transitive versions are in `bun.lock`. Complete package distributions include their shipped license texts/notices in `resources/javascript-LICENSES.txt`, collected from runtime dependencies by `Server/scripts/licenses.ts`.
- **Swift OpenAPI Runtime 1.11.0** and **Swift HTTP Types 1.8.0**, Apache-2.0, support the Swift API bindings. Exact revisions are pinned in `Package.resolved`; LICENSE and NOTICE texts from those checkouts are in `Resources/swift-openapi-runtime-LICENSE.txt` and `Resources/swift-http-types-LICENSE.txt`. [OpenAPI Runtime upstream](https://github.com/apple/swift-openapi-runtime/tree/1.11.0), [HTTP Types upstream](https://github.com/apple/swift-http-types/tree/1.8.0). **Swift OpenAPI Generator 1.13.1** and **openapi-typescript 7.10.1** are development tools used to regenerate committed bindings; their executable code is not bundled into the server.

## Native Swift text helper

Direct versions are exact pins in `TextEngine/Package.swift`; the complete resolved graph and commit revisions are in `TextEngine/Package.resolved`. License copies come from those exact upstream checkouts and are bundled through `Resources/*-LICENSE.txt`.

| Package | Version | License | Upstream |
| --- | --- | --- | --- |
| MLX Swift | 0.31.4 | MIT | [mlx-swift](https://github.com/ml-explore/mlx-swift/tree/0.31.4) |
| MLX Swift LM | 3.31.4 | MIT | [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm/tree/3.31.4) |
| Swift Transformers | 1.3.0 | Apache-2.0 | [swift-transformers](https://github.com/huggingface/swift-transformers/tree/1.3.0) |
| Swift Hugging Face | 0.10.0 | Apache-2.0 | [swift-huggingface](https://github.com/huggingface/swift-huggingface/tree/0.10.0) |
| Swift Jinja | 2.4.2 | Apache-2.0 | [swift-jinja](https://github.com/huggingface/swift-jinja/tree/2.4.2) |
| Swift Numerics | 1.1.1 | Apache-2.0 with Runtime Library Exception | [swift-numerics](https://github.com/apple/swift-numerics/tree/1.1.1) |
| Swift Collections | 1.6.0 | Apache-2.0 with Runtime Library Exception | [swift-collections](https://github.com/apple/swift-collections/tree/1.6.0) |
| Swift Crypto | 4.5.2 | Apache-2.0 | [swift-crypto](https://github.com/apple/swift-crypto/tree/4.5.2) |
| EventSource | 1.5.1 | MIT | [EventSource](https://github.com/mattt/EventSource/tree/1.5.1) |
| yyjson | 0.12.0 | MIT | [yyjson](https://github.com/ibireme/yyjson/tree/0.12.0) |
| Swift ASN.1 | 1.7.2 | Apache-2.0 | [swift-asn1](https://github.com/apple/swift-asn1/tree/1.7.2) |
| Swift Syntax | 603.0.2 | Apache-2.0 with Runtime Library Exception | [swift-syntax](https://github.com/swiftlang/swift-syntax/tree/603.0.2) |

The table is the **resolved package graph**, not a claim that every target is linked: Swift Syntax belongs to unused upstream macro products, and Swift ASN.1 belongs to CryptoExtras rather than the selected macOS Crypto product. Swift Crypto's selected macOS path uses CryptoKit; its conditional non-Apple BoringSSL targets are not selected. Upstream Crypto/ASN.1 NOTICE texts accompany their license copies. Hub/EventSource dependencies do not authorize network use: Inlay's helper loads tokenizers and models from the local verified directory and starts no server.

MLX Swift also vendors **MLX and MLX C** (MIT), **metal-cpp** (Apache-2.0), **{fmt} 12.1.0** (MIT with its upstream optional exception), **nlohmann/json 3.11.3** (MIT), and **PocketFFT** (BSD-3-Clause). Their exact license texts and MLX acknowledgments are preserved in `Resources/mlx-vendored-LICENSE.txt`.

## Linux text helper

- **llama.cpp / ggml**, MIT, pinned to b10516 (`b95502ba9aa0eb73a2f4fc8878d7fbe6a847a0b9`). [Source and license](https://github.com/ggml-org/llama.cpp/tree/b95502ba9aa0eb73a2f4fc8878d7fbe6a847a0b9). Linked into the Linux Qwen helper. Its source retains its bundled dependency notices, including nlohmann/json v3.12.0.
- **Qwen3-4B-Instruct-2507 Q4_K_M**, Apache-2.0. The Linux server uses the pinned [Unsloth GGUF conversion](https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/tree/a06e946bb6b655725eafa393f4a9745d460374c9). It is downloaded separately and verified by the server; see [model setup](Server/README.md#models).

Inlay is an independent exploratory project. It is not affiliated with Wispr, OpenAI, or the upstream projects.
