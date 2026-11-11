import Darwin
import Foundation

public enum ConfigurationFileError: LocalizedError, Equatable, Sendable {
    case missing
    case invalid(String)
    case unsafePath(path: String, reason: String)
    case io(operation: String, path: String, detail: String)
    case changedDuringWrite

    public var errorDescription: String? {
        switch self {
        case .missing: "config.json is missing. Restore the file to resume saving and loading preferences."
        case .invalid(let detail): "config.json was not loaded: \(detail) Your last valid settings are unchanged."
        case .unsafePath(let path, let reason): "Cannot use \(path): \(reason)"
        case .io(let operation, let path, let detail): "Could not \(operation) at \(path): \(detail)"
        case .changedDuringWrite: "config.json changed while it was being saved. Try the setting again."
        }
    }
}

/// Serial, bounded config I/O. Updates merge only changed top-level preferences into the
/// latest file, preserving unrelated external edits and unknown top-level JSON keys.
public actor ConfigurationFile {
    public nonisolated let url: URL
    public static let maximumFileSize = 1_048_576

    public init(url: URL? = nil) {
        self.url = (url ?? InlayBuild.current.dataDirectory
            .appendingPathComponent("config.json")).standardizedFileURL
    }

    /// Initial preferences are used only when the file is absent. Existing invalid files are not rewritten.
    public func load(orCreate initial: InlayConfiguration) -> Result<InlayConfiguration, ConfigurationFileError> {
        result {
            let directory = try openDirectory(create: true)
            defer { close(directory) }
            do { return try document(in: directory).configuration }
            catch ConfigurationFileError.missing {
                let data = try encoded(initial)
                let configuration = try decoded(data)
                do { try publish(data, in: directory, replacing: nil) }
                catch ConfigurationFileError.changedDuringWrite {
                    // An editor or another process created it first. Never replace that file.
                    return try document(in: directory).configuration
                }
                return configuration
            }
        }
    }

    public func read() -> Result<InlayConfiguration, ConfigurationFileError> {
        result {
            let directory = try openDirectory(create: false)
            defer { close(directory) }
            return try document(in: directory).configuration
        }
    }

    /// A removed or invalid config is never recreated by a settings edit.
    public func update(from previous: InlayConfiguration, to desired: InlayConfiguration)
        -> Result<InlayConfiguration, ConfigurationFileError> {
        result {
            let before = try object(encoded(previous))
            let afterData = try encoded(desired)
            _ = try decoded(afterData)
            let after = try object(afterData)
            let changedKeys = after.keys.filter { key in
                (before[key] as? NSObject)?.isEqual(after[key]) != true
            }
            let directory = try openDirectory(create: false)
            defer { close(directory) }
            for _ in 0..<3 {
                do {
                    let latest = try document(in: directory)
                    if changedKeys.isEmpty { return latest.configuration }
                    var merged = latest.object
                    for key in changedKeys { merged[key] = after[key] }
                    let data = try JSONSerialization.data(withJSONObject: merged,
                        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
                    let configuration = try decoded(data)
                    try publish(data, in: directory, replacing: latest.identity)
                    return configuration
                } catch ConfigurationFileError.changedDuringWrite { continue }
            }
            throw ConfigurationFileError.changedDuringWrite
        }
    }

    private struct Document {
        let configuration: InlayConfiguration
        let object: [String: Any]
        let identity: Identity
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private func result<Value>(_ operation: () throws -> Value) -> Result<Value, ConfigurationFileError> {
        do { return .success(try operation()) }
        catch let error as ConfigurationFileError { return .failure(error) }
        catch { return .failure(.io(operation: "use configuration", path: url.path, detail: error.localizedDescription)) }
    }

    private func encoded(_ configuration: InlayConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(configuration) + Data("\n".utf8)
    }

    private func decoded(_ data: Data) throws -> InlayConfiguration {
        guard data.count <= Self.maximumFileSize else {
            throw ConfigurationFileError.invalid("The file exceeds the 1 MiB limit.")
        }
        do { return try JSONDecoder().decode(InlayConfiguration.self, from: data) }
        catch let error as DecodingError {
            let context: DecodingError.Context
            switch error {
            case .dataCorrupted(let value), .keyNotFound(_, let value),
                 .typeMismatch(_, let value), .valueNotFound(_, let value): context = value
            @unknown default: throw ConfigurationFileError.invalid(error.localizedDescription)
            }
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ConfigurationFileError.invalid(path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)")
        } catch { throw ConfigurationFileError.invalid(error.localizedDescription) }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigurationFileError.invalid("The top level must be a JSON object.")
        }
        return object
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        let root = url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard url.isFileURL, root.path != "/", root != home,
              !url.lastPathComponent.isEmpty, url.lastPathComponent != ".", url.lastPathComponent != ".." else {
            throw ConfigurationFileError.unsafePath(path: url.path, reason: "Use a config file inside a dedicated app folder.")
        }
        let parent = open(root.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else {
            if errno == ENOENT { throw ConfigurationFileError.missing }
            throw ioError("open the configuration folder’s parent")
        }
        defer { close(parent) }
        var information = stat()
        if fstatat(parent, root.lastPathComponent, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw ioError("inspect the configuration folder") }
            guard create else { throw ConfigurationFileError.missing }
            if mkdirat(parent, root.lastPathComponent, mode_t(0o700)) != 0, errno != EEXIST {
                throw ioError("create the configuration folder")
            }
        } else if information.st_mode & S_IFMT == S_IFLNK {
            throw ConfigurationFileError.unsafePath(path: root.path, reason: "Symbolic links are not supported.")
        }
        let descriptor = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ioError("open the configuration folder") }
        guard fstat(descriptor, &information) == 0, information.st_uid == getuid() else {
            close(descriptor)
            throw ConfigurationFileError.unsafePath(path: root.path, reason: "The configuration folder must belong to this user.")
        }
        if create, fchmod(descriptor, mode_t(0o700)) != 0 {
            let error = ioError("make the configuration folder private")
            close(descriptor)
            throw error
        }
        return descriptor
    }

    private func document(in directory: Int32) throws -> Document {
        let expected = try identity(in: directory)
        let descriptor = openat(directory, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw ioError("read configuration") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw ioError("inspect configuration") }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid() else {
            throw ConfigurationFileError.unsafePath(path: url.path, reason: "Configuration must be a regular file owned by this user.")
        }
        guard Identity(information) == expected else { throw ConfigurationFileError.changedDuringWrite }
        guard information.st_size <= Self.maximumFileSize else {
            throw ConfigurationFileError.invalid("The file exceeds the 1 MiB limit.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ioError("read configuration") }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileSize else {
                throw ConfigurationFileError.invalid("The file exceeds the 1 MiB limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(descriptor, &information) == 0 else { throw ioError("inspect configuration") }
        guard Identity(information) == expected, try identity(in: directory) == expected else {
            throw ConfigurationFileError.changedDuringWrite
        }
        return Document(configuration: try decoded(data), object: try object(data), identity: expected)
    }

    private func identity(in directory: Int32) throws -> Identity {
        var information = stat()
        guard fstatat(directory, url.lastPathComponent, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw ConfigurationFileError.missing }
            throw ioError("inspect configuration")
        }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid() else {
            throw ConfigurationFileError.unsafePath(path: url.path, reason: "Configuration must be a regular file owned by this user, not a symbolic link.")
        }
        return Identity(information)
    }

    private func publish(_ data: Data, in directory: Int32, replacing expected: Identity?) throws {
        guard data.count <= Self.maximumFileSize else {
            throw ConfigurationFileError.invalid("The file exceeds the 1 MiB limit.")
        }
        let temporaryName = ".config-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw ioError("create a temporary configuration file") }
        defer {
            close(descriptor)
            unlinkat(directory, temporaryName, 0)
        }
        guard fchmod(directory, mode_t(0o700)) == 0, fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw ioError("make configuration private")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ioError("write configuration") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ioError("finish writing configuration") }

        // Editors often replace rather than edit a file. Recheck both the parent and file
        // before the atomic rename. A changed snapshot is reread and merged by update().
        var openRoot = stat()
        var currentRoot = stat()
        guard fstat(directory, &openRoot) == 0,
              lstat(url.deletingLastPathComponent().path, &currentRoot) == 0,
              currentRoot.st_mode & S_IFMT == S_IFDIR,
              currentRoot.st_dev == openRoot.st_dev, currentRoot.st_ino == openRoot.st_ino else {
            throw ConfigurationFileError.changedDuringWrite
        }
        if let expected {
            guard try identity(in: directory) == expected else { throw ConfigurationFileError.changedDuringWrite }
            guard renameat(directory, temporaryName, directory, url.lastPathComponent) == 0 else {
                throw ioError("replace configuration")
            }
        } else {
            guard renameatx_np(directory, temporaryName, directory, url.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ConfigurationFileError.changedDuringWrite }
                throw ioError("create configuration")
            }
        }
    }

    private func ioError(_ operation: String) -> ConfigurationFileError {
        .io(operation: operation, path: url.path, detail: String(cString: strerror(errno)))
    }
}
