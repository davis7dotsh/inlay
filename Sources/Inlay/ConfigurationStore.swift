import AppKit
import Combine
import Darwin
import InlayCore

/// One live settings snapshot. All file access is isolated from the UI and audio paths.
@MainActor
final class ConfigurationStore: ObservableObject {
    @Published private(set) var configuration: InlayConfiguration
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingWriteCount = 0
    @Published private(set) var isLoaded = false
    let url: URL

    private struct Edit {
        var before: InlayConfiguration
        var after: InlayConfiguration
    }

    private let file: ConfigurationFile
    private var lastValidConfiguration: InlayConfiguration
    private var pendingEdit: Edit?
    private var revision = 0
    private var readSequence = 0
    private var isWriting = false
    private var flushCount = 0
    private var startTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var watcher: ConfigurationWatcher?
    private var watchingStopped = false

    init(file: ConfigurationFile = .init()) {
        self.file = file
        url = file.url
        configuration = .default
        lastValidConfiguration = .default
    }

    /// Create device preferences on first launch; existing JSON remains authoritative.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            accept(await file.load(orCreate: .default), publish: pendingEdit == nil)
            if !watchingStopped {
                let watcher = ConfigurationWatcher(url: url) { [weak self] in
                    Task { @MainActor [weak self] in self?.scheduleReload() }
                }
                self.watcher = watcher
                await watcher.refresh()
                // Catch an external save between the initial read and watcher setup.
                accept(await file.read(), publish: pendingEdit == nil)
            }
            isLoaded = true
        }
        startTask = task
        await task.value
    }

    /// Edits are immediate in the UI, then batched and merged with the latest file.
    func update(_ edit: (inout InlayConfiguration) -> Void) {
        let before = configuration
        var after = before
        edit(&after)
        guard before != after else { return }
        revision += 1
        configuration = after
        if pendingEdit != nil {
            pendingEdit?.after = after
        } else {
            pendingEdit = Edit(before: before, after: after)
        }
        updatePendingCount()
        guard writeTask == nil else { return }
        writeTask = Task { [weak self] in
            guard let self else { return }
            await writePendingEdits()
        }
    }

    /// Both explicit reloads and filesystem notifications wait out our own writes.
    func reload() async {
        await start()
        await flush()
        let readRevision = revision
        readSequence += 1
        let sequence = readSequence
        await watcher?.refresh()
        let result = await file.read()
        // A user edit made during the read must not flash back to an older snapshot.
        if !Task.isCancelled, sequence == readSequence, readRevision == revision, pendingEdit == nil, !isWriting {
            accept(result, publish: true)
        }
    }

    func flush() async {
        flushCount += 1
        defer { flushCount -= 1 }
        if let startTask { await startTask.value }
        while let writeTask { await writeTask.value }
    }

    func stopWatching() {
        watchingStopped = true
        reloadTask?.cancel()
        reloadTask = nil
        watcher?.stop()
        watcher = nil
    }

    func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func writePendingEdits() async {
        await start()
        while pendingEdit != nil {
            // A text-field edit need not rewrite the file for every keystroke.
            if flushCount == 0 { try? await Task.sleep(for: .milliseconds(150)) }
            guard let edit = pendingEdit else { break }
            pendingEdit = nil
            isWriting = true
            updatePendingCount()
            let result = await file.update(from: edit.before, to: edit.after)
            isWriting = false
            if case .failure = result, pendingEdit != nil {
                // A newer edit still contains the earlier uncommitted changes.
                pendingEdit?.before = edit.before
            }
            accept(result, publish: pendingEdit == nil)
            updatePendingCount()
        }
        writeTask = nil
    }

    private func accept(_ result: Result<InlayConfiguration, ConfigurationFileError>, publish: Bool) {
        switch result {
        case .success(let saved):
            lastValidConfiguration = saved
            errorMessage = nil
            if publish, configuration != saved { configuration = saved }
        case .failure(let error):
            errorMessage = error.localizedDescription
            // Invalid files stay untouched; the UI returns to the last good settings.
            if publish, configuration != lastValidConfiguration { configuration = lastValidConfiguration }
        }
    }

    private func updatePendingCount() {
        pendingWriteCount = (isWriting ? 1 : 0) + (pendingEdit == nil ? 0 : 1)
    }

    private func scheduleReload() {
        guard !watchingStopped else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            await reload()
        }
    }
}

/// Watch the containing directory as well as the inode: editors often replace files.
/// Descriptor creation, re-arming and disposal never run on the main actor.
private final class ConfigurationWatcher: @unchecked Sendable {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "local.inlay.configuration-watch", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var stopped = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { sources.forEach { $0.cancel() } }

    func refresh() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }
                guard !stopped else { return }
                sources.forEach { $0.cancel() }
                sources.removeAll()
                let directory = url.deletingLastPathComponent()
                // If the settings directory is removed, observe its parent for recovery.
                if !watch(directory) { _ = watch(directory.deletingLastPathComponent()) }
                _ = watch(url)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
    }

    private func watch(_ path: URL) -> Bool {
        let descriptor = open(path.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, !stopped else { return }
            onChange()
        }
        source.setCancelHandler { close(descriptor) }
        sources.append(source)
        source.resume()
        return true
    }
}
