import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A runner holds this advisory lock for its entire lifetime so two independent
/// runners cannot mutate one archive.
final class DataDirectoryLock {
    private var descriptor: Int32?

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(".server.lock").path
        let opened = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard opened >= 0 else {
            throw ServerConfigurationError.invalid("Could not open the server data directory lock.")
        }
        var attributes = stat()
        guard fstat(opened, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            close(opened)
            throw ServerConfigurationError.invalid("The server data directory lock must be a regular file.")
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            close(opened)
            if failure == EWOULDBLOCK || failure == EAGAIN {
                throw ServerConfigurationError.invalid("Another V07 server is already using this data directory. Stop that runner or choose a different --data-dir.")
            }
            throw ServerConfigurationError.invalid("Could not acquire the server data directory lock.")
        }
        descriptor = opened
    }

    /// Keep the lock file in place: removing it could let another process lock a
    /// different inode while a waiting runner still owns this one.
    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}
