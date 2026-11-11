// Generated from Server/api/model-pins.json by generate-api.ts; edit the source, never this file.

public enum GeneratedModelPins {
    public struct Pin: Sendable {
        public let filename: String
        public let byteCount: Int64
        public let sha256: String
        public let url: String
    }

    public static let speechID = "parakeet-tdt-0.6b-v3"
    public static let speechName = "Parakeet TDT 0.6B v3"
    public static let speechFilename = "ggml-parakeet-tdt-0.6b-v3-f16.bin"
    public static let speechByteCount: Int64 = 1255897319
    public static let speechSHA256 = "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
    public static let speechURL = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-f16.bin"

    public static let textID = "qwen3-4b-instruct-2507-mlx-4bit"
    public static let textName = "Qwen3 4B Instruct (MLX)"
    public static let textDirectory = "Qwen3-4B-Instruct-2507-MLX-4bit"
    public static let textFiles: [Pin] = [
        Pin(filename: "model.safetensors", byteCount: 2263022417, sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/model.safetensors"),
        Pin(filename: "config.json", byteCount: 938, sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/config.json"),
        Pin(filename: "tokenizer.json", byteCount: 11422654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/tokenizer.json"),
        Pin(filename: "tokenizer_config.json", byteCount: 5440, sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/tokenizer_config.json"),
        Pin(filename: "generation_config.json", byteCount: 238, sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/generation_config.json"),
        Pin(filename: "chat_template.jinja", byteCount: 4040, sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541", url: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/chat_template.jinja"),
    ]
}
