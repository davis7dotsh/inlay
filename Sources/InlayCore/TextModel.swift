import CryptoKit
import Darwin
import Foundation

/// A pinned, non-thinking MLX model and the complete set of files it loads.
public struct TextModel: Sendable {
    public struct File: Sendable {
        public let filename: String
        public let byteCount: Int64
        public let sha256: String
        public let downloadURL: URL

        public init(filename: String, byteCount: Int64, sha256: String, downloadURL: URL) {
            self.filename = filename
            self.byteCount = byteCount
            self.sha256 = sha256
            self.downloadURL = downloadURL
        }
    }

    public let id: String
    public let name: String
    /// The directory name for an installed model artifact.
    public let filename: String
    public let files: [File]

    public init(id: String, name: String, filename: String, files: [File]) {
        self.id = id
        self.name = name
        self.filename = filename
        self.files = files
    }

    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }

    /// Identity of the full artifact, not just its weights. UTF-8 manifest lines
    /// are sorted by filename: filename + TAB + byte count + TAB + SHA256 + LF.
    public var sha256: String {
        let manifest = files.sorted { $0.filename < $1.filename }.map {
            "\($0.filename)\t\($0.byteCount)\t\($0.sha256)\n"
        }.joined()
        return SHA256.hash(data: Data(manifest.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static let qwen: TextModel = {
        let base = URL(string: "https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b/")!
        let entries: [(String, Int64, String)] = [
            ("model.safetensors", 2_263_022_417, "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
            ("config.json", 938, "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
            ("tokenizer.json", 11_422_654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
            ("tokenizer_config.json", 5_440, "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
            ("generation_config.json", 238, "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
            ("chat_template.jinja", 4_040, "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
        ]
        return TextModel(
            id: "qwen3-4b-instruct-2507-mlx-4bit", name: "Qwen3 4B Instruct (MLX)",
            filename: "Qwen3-4B-Instruct-2507-MLX-4bit",
            files: entries.map { File(filename: $0.0, byteCount: $0.1, sha256: $0.2,
                                      downloadURL: base.appendingPathComponent($0.0)) }
        )
    }()

    public func verify(_ directory: URL) -> Result<Void, ModelIntegrityError> {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == ENOENT ? .failure(.missing) : .failure(.unreadable("The model must be a regular directory, not a symbolic link."))
        }
        defer { close(descriptor) }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard Set(names) == Set(files.map(\.filename)), names.count == files.count else {
                return .failure(.unreadable("The model folder has missing or unexpected files. Download it again."))
            }
            for file in files {
                guard !file.filename.isEmpty, file.filename != ".", file.filename != "..",
                      !file.filename.contains("/"), !file.filename.contains("\0") else {
                    return .failure(.unreadable("Invalid model manifest."))
                }
                let result = verifyFile(file, in: descriptor)
                if case .failure = result { return result }
            }
            return .success(())
        } catch { return .failure(.unreadable(error.localizedDescription)) }
    }

    private func verifyFile(_ file: File, in directory: Int32) -> Result<Void, ModelIntegrityError> {
        let descriptor = openat(directory, file.filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(.unreadable("Cannot read \(file.filename) as a regular file.")) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return .failure(.unreadable("\(file.filename) is not a regular file."))
        }
        guard info.st_size == file.byteCount else {
            return .failure(.wrongSize(expected: file.byteCount, actual: info.st_size))
        }
        do {
            var digest = SHA256()
            var count: Int64 = 0
            while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
                if Task.isCancelled { return .failure(.unreadable("Model verification was cancelled.")) }
                count += Int64(data.count)
                guard count <= file.byteCount else { return .failure(.wrongSize(expected: file.byteCount, actual: count)) }
                digest.update(data: data)
            }
            guard count == file.byteCount else { return .failure(.wrongSize(expected: file.byteCount, actual: count)) }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == file.sha256 ? .success(()) : .failure(.wrongDigest)
        } catch { return .failure(.unreadable(error.localizedDescription)) }
    }
}
