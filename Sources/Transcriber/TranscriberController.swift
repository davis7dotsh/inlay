import AppKit
import Combine
import OSLog
import TranscriberAPI
import TranscriberCore
import ServiceManagement

private enum DictationDestination: Equatable {
    case test
    case field(InsertionTarget)
}

struct WisprFlowImportCounts {
    var processed = 0
    var total = 0
    var imported = 0
    var enriched = 0
    var skipped = 0
    var partial = 0
    var failed = 0
    var dictionaryArchived = false
    var warning: String?
    var unarchivedWarning: String?
}

enum WisprFlowImportState {
    case idle
    case preparing
    case preview(WisprFlowImportPreview, knownCount: Int?, destinationError: String?)
    case running(WisprFlowImportPreview, WisprFlowImportCounts)
    case finished(WisprFlowImportPreview, WisprFlowImportCounts, cancelled: Bool)
    case failed(String)
}

/// The snapshot worker is independent of the main actor. This gate lets quit
/// wait for it and close a reader that has not yet reached the controller.
private final class WisprFlowPreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let work = DispatchGroup()
    private var cancelled = false
    private var reader: WisprFlowSourceReader?

    init() { work.enter() }
    func finish() { work.leave() }

    func register(_ value: WisprFlowSourceReader) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        reader = value
        return true
    }

    func transfer(_ value: WisprFlowSourceReader) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, reader === value else { return false }
        reader = nil
        return true
    }

    func cancel(waitForWorker: Bool = false) {
        lock.lock()
        cancelled = true
        let value = reader
        reader = nil
        lock.unlock()
        if waitForWorker {
            value?.close()
            work.wait()
        } else if let value {
            Task.detached(priority: .utility) { value.close() }
        }
    }
}

/// The desktop never owns a durable generation or a model process. A take has
/// one accepted server generation, one bounded upload, and at most one delivery.
@MainActor
final class TranscriberController: ObservableObject {
    @Published var activity: DictationActivity = .idle
    let recordingFeedback = RecordingFeedback()
    @Published var recordingListHint: String?
    @Published private(set) var recordingInputName: String?
    @Published var lastTranscript = ""
    @Published var lastTranscriptionSeconds: Double?
    @Published var lastAudioSeconds: Double?
    @Published var lastDelivery = ""
    @Published private(set) var lastDeliveryStatus: DictationDeliveryStatus = .none
    @Published var errorMessage: String?
    @Published var permissions: PermissionSnapshot
    @Published var isHotkeyActive = false
    @Published private(set) var isCheckingShortcut = false
    @Published private(set) var shortcutCheckText = ""
    /// Fork: every listed key starts and stops dictation the same way.
    @Published var shortcuts: [HoldKey] = [.rightOption] {
        didSet {
            if shortcuts != oldValue { stopShortcutCheck() }
            if !applyingConfiguration { configuration.update { $0.holdKeys = shortcuts.map(\.token) } }
            hotkey.keys = shortcuts
        }
    }
    /// Fork: the next key pressed in a Transcriber window joins `shortcuts`.
    @Published private(set) var isAddingShortcut = false
    @Published var activationMode: HotkeyActivationMode = .hold {
        didSet {
            guard activationMode != oldValue else { return }
            if !applyingConfiguration { configuration.update { $0.activationMode = activationMode.rawValue } }
            hotkey.mode = activationMode
        }
    }
    @Published var launchAtLogin = false {
        didSet {
            guard hasInitialized, !applyingConfiguration, !updatingLogin, launchAtLogin != oldValue else { return }
            configuration.update { $0.launchAtLogin = launchAtLogin }
            updateLoginItem()
        }
    }
    @Published private(set) var loginItemError: String?
    @Published var muteOutputWhileRecording = false {
        didSet {
            if !applyingConfiguration { configuration.update { $0.muteOutputWhileRecording = muteOutputWhileRecording } }
        }
    }
    @Published var dictationSoundsEnabled = true {
        didSet {
            if !applyingConfiguration { configuration.update { $0.dictationSoundsEnabled = dictationSoundsEnabled } }
        }
    }
    @Published var statusMessage = "Connecting to server…"
    @Published private(set) var hudProgressText: String?
    @Published private(set) var serverHealth: ServerHealth?
    @Published private(set) var serverStatusMessage = "Connecting…"
    @Published private(set) var isCheckingServer = false
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var sharedPreferences: PreferencesSnapshot?
    @Published private(set) var generations: [GenerationRecord] = []
    @Published private(set) var undeliveredResults: [GenerationRecord] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var historySourceFilter = "all"
    @Published private(set) var wisprFlowImportState: WisprFlowImportState = .idle
    private var historyCursor: String?
    private var wisprFlowReader: WisprFlowSourceReader?
    private var wisprFlowPrepareTask: Task<Void, Never>?
    private var wisprFlowPrepareGate: WisprFlowPreparationGate?
    private var wisprFlowPrepareRevision = 0
    private var wisprFlowImportTask: Task<Void, Never>?
    private var wisprFlowMaterializationTask: Task<WisprFlowSourceSession, Error>?
    private var wisprFlowImportRevision = 0
    private var wisprFlowActiveReaders: [Int: WisprFlowSourceReader] = [:]
    private var wisprFlowDestinationEndpoint: String?
    let configuration: ConfigurationStore
    let microphones: MicrophonePreferencesStore
    let preferences: ClientPreferencesStore
    private let pendingStore: PendingGenerationsStore
    private var pendingEntries: [PendingGenerationEntry]
    private var isReconcilingPending = false

    var isRecording: Bool { activity == .recording }
    var isCapturing: Bool { activity.isCapturing }
    var recordingUsesClipboard: Bool { isCapturing && insertionDestination == .clipboard }
    var isBusy: Bool { activity.isBusy || !pendingDictations.isEmpty }
    var pendingDictationCount: Int { pendingDictations.count }
    var canCancelWithEscape: Bool { isCapturing && !hotkey.isHoldingDedicatedKey }
    var isServerReady: Bool { serverHealth?.ready == true && serverHealth?.apiVersion == TranscriberAPI.version }
    var canTest: Bool { isServerReady && permissions.microphone && microphones.resolution.device != nil && !isCapturing }
    var selectedInputName: String { microphones.resolution.device?.name ?? "No microphone available" }
    var allPermissionsGranted: Bool { permissions.microphone && permissions.accessibility }
    var onHUDVisibility: ((Bool) -> Void)?
    var onShowWindow: (() -> Void)?

    private let recorder: AudioRecorder
    private let audioDevices: AudioDeviceStore
    private let serverClientFactory: (() throws -> ServerClient)?
    private let hotkey = HotkeyMonitor()
    private let outputMuter = SystemOutputMuter()
    private var subscriptions: Set<AnyCancellable> = []
    private var applyingConfiguration = false
    private var recordingTimer: Timer?
    private var recordingStart: TimeInterval = 0
    /// Uptime of the last sustained voice. A value from an earlier take is
    /// below `recordingStart`, so it never needs a reset.
    private var lastVoiceAt: TimeInterval = 0
    private var microphoneStartTask: Task<Void, Never>?
    private var recorderStopTask: Task<CapturedAudio, Error>?
    private var deliveryTail: Task<Void, Never>?
    private var insertionRebases = ConfirmedInsertionRebases<InsertionTarget>()
    /// Released takes in recording order. The newest may own the HUD via sessionID.
    @Published private var pendingDictations: [PendingDictation] = []
    private var uploadTask: Task<FinishGenerationRequest, Error>?
    private var uploadPipe: AudioChunkPipe?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var shortcutCheckTask: Task<Void, Never>?
    private var shortcutCheckStarted: TimeInterval = 0
    private var shortcutCheckEntries: [String] = []
    private var shortcutCapture: Any?
    private var shortcutCaptureTimeout: Task<Void, Never>?
    private var sessionID = UUID()
    /// Fork: the server record a take uploads into. The microphone starts while
    /// its create request is in flight, so every consumer awaits this task
    /// instead of reading a generation ID that is known synchronously.
    private struct StartedGeneration: Sendable {
        let id: UUID
        let client: ServerClient
        let preserveOriginal: Bool
    }
    private var activeGeneration: Task<StartedGeneration, Error>?
    @MainActor
    private final class PendingDictation {
        let session: UUID
        let generation: Task<StartedGeneration, Error>
        let upload: Task<FinishGenerationRequest, Error>
        let pipe: AudioChunkPipe
        let destination: InsertionDestinationCapture?
        /// Fork: the apps around the take at its start, sent after delivery as data only.
        let appContext: Task<AppContext, Never>?
        var task: Task<Void, Never>?
        var sealed = false
        /// Fork: only an explicit user cancel deletes the take's local audio.
        var discardsAudio = false
        /// Fork: set once the take may touch the clipboard or the focused field.
        var delivering = false
        /// Fork: set when the Mac locked or slept before delivery. The take then
        /// reaches only the clipboard.
        var restedSinceRelease = false
        var generationID: UUID?
        /// Set once the take needs no relaunch recovery, so its pending entry can go.
        var resolved = false
        /// Nil until the destination resolves; list continuation keys off its anchor.
        var target: (destination: InsertionDestination, anchor: DictationDestination?)?
        /// Fork: later takes deliver after this opens, not after the task ends,
        /// so a cancelled take's background create and cleanup never delay them.
        private let settled: AsyncStream<Void>
        private let settledContinuation: AsyncStream<Void>.Continuation

        init(session: UUID, generation: Task<StartedGeneration, Error>, upload: Task<FinishGenerationRequest, Error>,
             pipe: AudioChunkPipe, destination: InsertionDestinationCapture?, appContext: Task<AppContext, Never>?) {
            self.session = session; self.generation = generation; self.upload = upload
            self.pipe = pipe; self.destination = destination; self.appContext = appContext
            (settled, settledContinuation) = AsyncStream<Void>.makeStream()
        }

        func cancel() {
            task?.cancel(); upload.cancel(); pipe.cancel(); destination?.cancel(); appContext?.cancel()
            // A take already delivering keeps later takes waiting until it stops.
            if !delivering { settle() }
        }

        func settle() { settledContinuation.finish() }
        func waitUntilSettled() async { for await _ in settled {} }

        func cancelOnServer() { TranscriberController.cancelOnServer(generation) }
    }

    /// Fork: a take can end while its create request is in flight. Cancel the
    /// server record once it exists, instead of leaving it receiving.
    private static func cancelOnServer(_ generation: Task<StartedGeneration, Error>) {
        Task { if let started = try? await generation.value { try? await started.client.cancel(started.id) } }
    }
    @Published private var insertionDestination: InsertionDestination?
    private var destinationTask: InsertionDestinationCapture?
    private var appContextTask: Task<AppContext, Never>?
    private var recordingClipboardChangeCount = 0
    private struct ContinuationAnchor {
        let destination: DictationDestination
        let generationID: UUID
        let continuation: DictationContinuation
        let timestamp: TimeInterval
    }
    private var continuationAnchors: [ContinuationAnchor] = []
    private var isTestSession = false
    private var updatingLogin = false
    private var hasInitialized = false
    private var isShuttingDown = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(configuration: ConfigurationStore, startServices: Bool = true,
         recorder: AudioRecorder? = nil, audioDevices: AudioDeviceStore? = nil,
         serverClient: (() throws -> ServerClient)? = nil) {
        self.configuration = configuration
        self.recorder = recorder ?? AudioRecorder()
        self.audioDevices = audioDevices ?? AudioDeviceStore()
        self.serverClientFactory = serverClient
        preferences = ClientPreferencesStore(root: configuration.url.deletingLastPathComponent())
        let loadedPendingStore = PendingGenerationsStore(root: configuration.url.deletingLastPathComponent())
        pendingStore = loadedPendingStore
        pendingEntries = loadedPendingStore.load()
        // Fork: takes are written beside the client settings, not in the temporary directory.
        RecordingStorage.configure(clientDataDirectory: configuration.url.deletingLastPathComponent())
        microphones = MicrophonePreferencesStore(configuration: configuration)
        permissions = startServices ? PermissionSnapshot.capture()
            : PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)
        applyConfiguration(configuration.configuration)
        hotkey.keys = shortcuts
        microphones.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        configuration.$configuration.removeDuplicates().sink { [weak self] in self?.applyConfiguration($0) }.store(in: &subscriptions)
        guard startServices else { preferences.loadCredential(); return }
        bindServices()
        // Fork: the first device list also starts the ready microphone, on the
        // capture queue. The token is read after it: Keychain can hold this
        // thread on an access prompt after an update. The shortcut listener
        // starts after the read, so a press made during that prompt is never
        // delivered late.
        self.audioDevices.start()
        preferences.loadCredential()
        installLifecycleObservers()
        refreshPermissions()
        // Fork: a take left behind by a crash is kept for recovery, not deleted.
        // Server history is never examined here.
        RecordingStorage.recoverRemnants()
        try? FileManager.default.removeItem(at: TranscriberTemporaryDirectory.url.appendingPathComponent("Transcriber-remote-preview"))
        hasInitialized = true
        updateLoginItem()
        refreshServer()
        monitorTask = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !isShuttingDown else { return }
                await checkServer(refreshData: count % 3 == 0 && !isBusy)
                count += 1
            }
        }
    }

    private func applyConfiguration(_ settings: TranscriberConfiguration) {
        guard !isBusy, !isShuttingDown else { return }
        applyingConfiguration = true
        let keys = settings.holdKeys.compactMap(HoldKey.init(token:))
        if !keys.isEmpty, shortcuts != keys { shortcuts = keys }
        if let mode = HotkeyActivationMode(rawValue: settings.activationMode), activationMode != mode { activationMode = mode }
        if launchAtLogin != settings.launchAtLogin { launchAtLogin = settings.launchAtLogin }
        if muteOutputWhileRecording != settings.muteOutputWhileRecording { muteOutputWhileRecording = settings.muteOutputWhileRecording }
        if dictationSoundsEnabled != settings.dictationSoundsEnabled { dictationSoundsEnabled = settings.dictationSoundsEnabled }
        applyingConfiguration = false
    }

    private func client() throws -> ServerClient {
        try serverClientFactory?() ?? ServerClient(endpoint: preferences.endpoint, token: preferences.token)
    }

    func refreshServer() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.checkServer(refreshData: true) }
    }

    private func checkServer(refreshData: Bool) async {
        guard !isCheckingServer, !isShuttingDown else { return }
        isCheckingServer = true
        let endpoint = preferences.endpoint
        defer { isCheckingServer = false }
        do {
            let connection = try client()
            let health = try await connection.health()
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            serverHealth = health
            serverStatusMessage = health.apiVersion != TranscriberAPI.version ? "Server API version is incompatible"
                : (health.ready ? "Server online" : (health.message ?? "Server models are not ready"))
            if !isBusy, activity == .idle { statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage }
            if refreshData {
                let source = historySourceFilter
                async let settings = connection.preferences()
                async let page = connection.history(source: source == "all" ? nil : source)
                let (saved, history) = try await (settings, page)
                guard endpoint == preferences.endpoint, source == historySourceFilter, !Task.isCancelled else { return }
                sharedPreferences = saved
                if generations.count > history.items.count, history.nextCursor != nil,
                   let oldest = history.items.last?.createdAt {
                    let ids = Set(history.items.map(\.id))
                    let older = generations.filter { $0.createdAt < oldest && !ids.contains($0.id) }
                    generations = history.items + older
                } else {
                    generations = history.items
                    historyCursor = history.nextCursor
                    hasMoreHistory = history.nextCursor != nil
                }
                await reconcilePendingGenerations()
            }
        } catch is CancellationError {
        } catch {
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            serverHealth = nil
            serverStatusMessage = Self.connectionMessage(error)
            if !isBusy, activity == .idle { statusMessage = serverStatusMessage }
        }
    }

    func saveConnection(endpoint: String, token: String, deviceName: String) {
        guard !isBusy, wisprFlowImportTask == nil else { return }
        guard preferences.save(endpoint: endpoint, token: token, deviceName: deviceName) else {
            errorMessage = preferences.errorMessage
            return
        }
        continuationAnchors.removeAll()
        // Renaming or re-entering a token for the same server keeps its pending results.
        pendingEntries.removeAll { $0.endpoint != preferences.endpoint }
        undeliveredResults.removeAll { result in !pendingEntries.contains { $0.id == result.id } }
        pendingStore.save(pendingEntries)
        serverHealth = nil
        sharedPreferences = nil
        generations = []
        historyCursor = nil
        hasMoreHistory = false
        serverStatusMessage = "Connecting…"
        refreshServer()
    }

    func refreshHistory() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let endpoint = preferences.endpoint
                let source = historySourceFilter
                let page = try await client().history(source: source == "all" ? nil : source)
                guard endpoint == preferences.endpoint, source == historySourceFilter else { return }
                generations = page.items
                historyCursor = page.nextCursor
                hasMoreHistory = page.nextCursor != nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func loadMoreHistory() {
        guard !isLoadingHistory, let cursor = historyCursor else { return }
        isLoadingHistory = true
        Task { [weak self] in
            guard let self else { return }
            defer { isLoadingHistory = false }
            do {
                let endpoint = preferences.endpoint
                let source = historySourceFilter
                let page = try await client().history(before: cursor, source: source == "all" ? nil : source)
                guard endpoint == preferences.endpoint, historyCursor == cursor, source == historySourceFilter else { return }
                let existing = Set(generations.map(\.id))
                generations += page.items.filter { !existing.contains($0.id) }
                historyCursor = page.nextCursor
                hasMoreHistory = page.nextCursor != nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func setHistorySourceFilter(_ source: String) {
        guard ["all", "transcriber", "wispr-flow"].contains(source), source != historySourceFilter else { return }
        historySourceFilter = source
        generations = []
        historyCursor = nil
        hasMoreHistory = false
        refreshHistory()
    }

    func prepareWisprFlowImport() {
        guard wisprFlowImportTask == nil else { return }
        wisprFlowPrepareRevision += 1
        let revision = wisprFlowPrepareRevision
        wisprFlowPrepareTask?.cancel()
        wisprFlowPrepareGate?.cancel()
        let gate = WisprFlowPreparationGate()
        wisprFlowPrepareGate = gate
        retireWisprFlowReader()
        wisprFlowImportState = .preparing
        wisprFlowDestinationEndpoint = preferences.endpoint
        // Schedule the worker before the main-actor continuation. Quit may
        // synchronously wait on the gate before that continuation starts.
        let snapshotTask = Task.detached(priority: .utility) {
            defer { gate.finish() }
            let reader = try WisprFlowSourceReader()
            guard gate.register(reader) else {
                reader.close()
                throw CancellationError()
            }
            return reader
        }
        wisprFlowPrepareTask = Task { [weak self] in
            guard let self else { gate.cancel(); return }
            defer {
                if revision == wisprFlowPrepareRevision { wisprFlowPrepareTask = nil }
            }
            do {
                let reader = try await snapshotTask.value
                var transferred = false
                defer {
                    if !transferred {
                        Task.detached(priority: .utility) { reader.close() }
                    }
                }
                try Task.checkCancellation()
                guard revision == wisprFlowPrepareRevision else { return }
                guard gate.transfer(reader) else { return }
                wisprFlowReader = reader
                transferred = true
                let knownCount: Int?
                let destinationError: String?
                do {
                    knownCount = try await client().knownWisprFlowSourceIDs(reader.sourceIDs).count
                    destinationError = nil
                } catch {
                    knownCount = nil
                    if let clientError = error as? ServerClientError,
                       case .rejected(let status, _) = clientError, status == 404 {
                        destinationError = "This server does not support Wispr Flow imports. Connect the new Transcriber Dev server."
                    } else {
                        destinationError = "Cannot check the destination server: \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                guard revision == wisprFlowPrepareRevision else { return }
                wisprFlowImportState = .preview(reader.preview, knownCount: knownCount,
                                               destinationError: destinationError)
            } catch is CancellationError {
            } catch {
                guard revision == wisprFlowPrepareRevision, !Task.isCancelled else { return }
                wisprFlowImportState = .failed(error.localizedDescription)
            }
        }
    }

    func startWisprFlowImport() {
        guard case .preview(let preview, _, let destinationError) = wisprFlowImportState,
              destinationError == nil,
              let reader = wisprFlowReader,
              wisprFlowImportTask == nil, !isBusy else { return }
        guard wisprFlowDestinationEndpoint == preferences.endpoint else {
            wisprFlowImportState = .failed("The server connection changed. Preview the import again.")
            return
        }
        let connection: ServerClient
        do { connection = try client() }
        catch { wisprFlowImportState = .failed(error.localizedDescription); return }
        let counts = WisprFlowImportCounts(total: reader.sourceIDs.count)
        wisprFlowImportRevision += 1
        let revision = wisprFlowImportRevision
        // The import task owns this reader until its detached work and artifact
        // cleanup finish. A new preview may start immediately after cancellation.
        wisprFlowActiveReaders[revision] = reader
        wisprFlowReader = nil
        wisprFlowImportState = .running(preview, counts)
        wisprFlowImportTask = Task { [weak self] in
            await self?.runWisprFlowImport(reader: reader, preview: preview, connection: connection,
                                           counts: counts, revision: revision)
        }
    }

    func cancelWisprFlowImport() {
        if case .running(let preview, let counts) = wisprFlowImportState {
            // Awaiting an unstructured reader task does not wake when its parent
            // is cancelled. Release the sheet now; the old task retains and
            // cleans its reader when materialization actually stops.
            wisprFlowImportRevision += 1
            wisprFlowMaterializationTask?.cancel()
            wisprFlowMaterializationTask = nil
            wisprFlowImportTask?.cancel()
            wisprFlowImportTask = nil
            wisprFlowDestinationEndpoint = nil
            wisprFlowImportState = .finished(preview, counts, cancelled: true)
        }
        wisprFlowPrepareTask?.cancel()
    }

    func closeWisprFlowImportSheet() {
        guard wisprFlowImportTask == nil else { return }
        wisprFlowPrepareRevision += 1
        wisprFlowPrepareTask?.cancel()
        wisprFlowPrepareGate?.cancel()
        retireWisprFlowReader()
        wisprFlowDestinationEndpoint = nil
        wisprFlowImportState = .idle
    }

    private func runWisprFlowImport(reader: WisprFlowSourceReader, preview: WisprFlowImportPreview,
                                    connection: ServerClient, counts initialCounts: WisprFlowImportCounts,
                                    revision: Int) async {
        var counts = initialCounts
        var cancelled = false
        var stoppedEarly = false
        var completionAttempted = false
        for sourceID in reader.sourceIDs {
            if Task.isCancelled { cancelled = true; break }
            var materializedSession: WisprFlowSourceSession?
            var activeTransferID: UUID?
            do {
                let session = try await materializeWisprFlowSession(reader: reader, sourceID: sourceID,
                                                                     revision: revision)
                materializedSession = session
                try Task.checkCancellation()
                let manifests = try await Task.detached(priority: .utility) {
                    try session.artifacts.map {
                        try ServerClient.wisprFlowArtifactManifest(filename: $0.filename, url: $0.url)
                    }
                }.value
                try Task.checkCancellation()
                let input = WisprFlowImportRequest(sourceID: session.sourceID, createdAt: session.createdAt,
                                                   sourceStatus: session.sourceStatus, finalText: session.displayText,
                                                   rawText: session.rawText, durationSeconds: session.durationSeconds,
                                                   variantNames: session.availableVariants, artifacts: manifests,
                                                   unarchivedArtifacts: session.unarchivedArtifacts.isEmpty
                                                       ? nil : session.unarchivedArtifacts)
                let transfer = try await connection.beginWisprFlowImport(input)
                activeTransferID = transfer.id
                for (artifact, manifest) in zip(session.artifacts, manifests) {
                    try Task.checkCancellation()
                    let receipt = try await connection.uploadWisprFlowArtifact(artifact.url, filename: artifact.filename,
                                                                               contentType: artifact.contentType, to: transfer.id)
                    guard receipt.filename == manifest.filename, receipt.byteCount == manifest.byteCount else {
                        throw ServerClientError.invalidResponse
                    }
                }
                try Task.checkCancellation()
                // A cancelled/lost response can hide a durable server commit.
                completionAttempted = true
                let result = try await connection.completeWisprFlowImport(transfer.id)
                activeTransferID = nil
                switch result.outcome {
                case .imported: counts.imported += 1
                case .enriched: counts.enriched += 1
                case .skipped: counts.skipped += 1
                case .partial:
                    counts.partial += 1
                    if counts.unarchivedWarning == nil {
                        let sourceReported = session.unarchivedArtifacts.map { omitted in
                            "\(omitted.filename.rawValue) (\(ByteCountFormatter.string(fromByteCount: Int64(omitted.byteCount), countStyle: .file)), SHA-256 \(omitted.sha256))"
                        }
                        let mediaNames = sourceReported.isEmpty
                            ? result.unarchivedArtifactNames.map(\.rawValue).joined(separator: ", ")
                            : sourceReported.joined(separator: ", ")
                        let mediaWarning = mediaNames.isEmpty ? nil
                            : "Session \(sourceID.uuidString) has unarchived media: \(mediaNames). Source version details are in source.json."
                        let warnings = [mediaWarning, session.provenanceWarning].compactMap { $0 }
                        if !warnings.isEmpty { counts.unarchivedWarning = warnings.joined(separator: "\n") }
                    }
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                if Task.isCancelled {
                    cancelled = true
                } else {
                    counts.failed += 1
                    if counts.warning == nil {
                        counts.warning = "Session \(sourceID.uuidString): \(error.localizedDescription)"
                    }
                    if error is URLError { stoppedEarly = true }
                    if let clientError = error as? ServerClientError,
                       case .rejected(let status, _) = clientError, [401, 403].contains(status) {
                        stoppedEarly = true
                    }
                }
            }
            if let activeTransferID {
                Task.detached(priority: .utility) {
                    try? await connection.cancelWisprFlowImport(activeTransferID)
                }
            }
            if let materializedSession {
                Task.detached(priority: .utility) {
                    reader.discardArtifacts(for: materializedSession)
                }
            }
            if Task.isCancelled { cancelled = true }
            if cancelled { break }
            counts.processed += 1
            if revision == wisprFlowImportRevision { wisprFlowImportState = .running(preview, counts) }
            if stoppedEarly { break }
        }
        if !cancelled, !stoppedEarly, preview.dictionaryCount > 0 {
            do {
                let dictionary = try await Task.detached(priority: .utility) {
                    try reader.dictionaryArtifactURL()
                }.value
                try Task.checkCancellation()
                guard let dictionary else { throw ServerClientError.invalidResponse }
                _ = try await connection.archiveWisprFlowDictionary(dictionary)
                counts.dictionaryArchived = true
            } catch is CancellationError {
                cancelled = true
            } catch {
                let dictionaryWarning = "Dictionary archive failed: \(error.localizedDescription)"
                counts.warning = [counts.warning, dictionaryWarning].compactMap { $0 }.joined(separator: "\n")
            }
        }
        cancelled = cancelled || Task.isCancelled
        await Task.detached(priority: .utility) { reader.close() }.value
        wisprFlowActiveReaders.removeValue(forKey: revision)
        if completionAttempted || counts.imported + counts.enriched + counts.skipped + counts.partial > 0 {
            if revision == wisprFlowImportRevision, historySourceFilter != "wispr-flow" {
                setHistorySourceFilter("wispr-flow")
            } else {
                // A cancelled run can still have committed on the server.
                // Refresh the user's current view without changing its filter.
                refreshHistory()
            }
        }
        guard revision == wisprFlowImportRevision else { return }
        wisprFlowImportTask = nil
        wisprFlowDestinationEndpoint = nil
        wisprFlowImportState = .finished(preview, counts, cancelled: cancelled)
    }

    private func materializeWisprFlowSession(reader: WisprFlowSourceReader, sourceID: UUID,
                                              revision: Int) async throws -> WisprFlowSourceSession {
        let task = Task.detached(priority: .utility) {
            try reader.session(for: sourceID)
        }
        if revision == wisprFlowImportRevision { wisprFlowMaterializationTask = task }
        defer {
            if revision == wisprFlowImportRevision { wisprFlowMaterializationTask = nil }
        }
        return try await task.value
    }

    private func retireWisprFlowReader() {
        guard let reader = wisprFlowReader else { return }
        wisprFlowReader = nil
        Task.detached(priority: .utility) { reader.close() }
    }

    func updateSharedPreferences(_ value: ServerPreferences, expectedRevision: Int? = nil) {
        guard !isSavingPreferences, let snapshot = sharedPreferences else { return }
        isSavingPreferences = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingPreferences = false }
            do {
                let endpoint = preferences.endpoint
                let saved = try await client().updatePreferences(.init(revision: expectedRevision ?? snapshot.revision, preferences: value))
                guard endpoint == preferences.endpoint else { return }
                sharedPreferences = saved
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription; refreshServer() }
        }
    }

    func transcribeAgain(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let connection = try client()
                replaceGeneration(try await connection.reprocess(id))
                // The 15 s History refresh covers a stream that ends early.
                _ = try await connection.events(id) { [weak self] record in
                    await self?.replaceGeneration(record)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func replaceGeneration(_ record: GenerationRecord) {
        guard let index = generations.firstIndex(where: { $0.id == record.id }) else { return }
        generations[index] = record
    }

    func deleteGeneration(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client().delete(id)
                generations.removeAll { $0.id == id }
                continuationAnchors.removeAll { $0.generationID == id }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func openGenerationAudio(_ generation: GenerationRecord, kind: AudioKind) {
        Task { [weak self] in
            guard let self else { return }
            do { NSWorkspace.shared.open(try await client().audio(generation.id, kind: kind)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func openWisprFlowArtifact(_ generation: GenerationRecord, filename: WisprFlowArtifactName) {
        guard generation.importedSource?.artifactNames.contains(filename) == true else { return }
        Task { [weak self] in
            guard let self else { return }
            do { NSWorkspace.shared.open(try await client().wisprFlowArtifact(generation.id, filename: filename)) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private static func connectionMessage(_ error: Error) -> String {
        if error is URLError { return "Server offline · Recording unavailable" }
        return error.localizedDescription
    }

    func toggleTestRecording() {
        guard !hotkey.isHoldingDedicatedKey else { return }
        if isCapturing { finishDictation() }
        else { beginDictation(isTest: true) }
    }

    func cancelDictation() {
        guard isBusy else { return }
        if isCapturing {
            let generation = activeGeneration
            resetSession()
            if let generation { Self.cancelOnServer(generation) }
        } else if activity.isBusy, let index = pendingDictations.lastIndex(where: { $0.session == sessionID }) {
            let pending = pendingDictations.remove(at: index)
            pending.discardsAudio = true // Fork: an explicit cancel deletes the local audio.
            pending.cancel()
            pending.cancelOnServer()
            // Fork: a take the user cancelled never comes back as a copy offer.
            if let id = pending.generationID { removePendingEntry(id) }
        } else if let earlier = pendingDictations.last {
            // The HUD shows a settled result or error. Dismissing it must not
            // cancel older work that the HUD does not show.
            errorMessage = nil
            showEarlierDictation(earlier)
            return
        }
        let remaining = pendingDictations.last?.session
        sessionID = remaining ?? UUID()
        activity = remaining == nil ? .idle : .transcribing
        // Fork: clear even when an earlier take remains, so its HUD never shows
        // the cancelled take's stage. It reads "Processing" until its next event.
        hudProgressText = nil
        statusMessage = remaining == nil ? "Cancelled" : "Cancelled · Earlier dictation is still processing"
        errorMessage = nil
        onHUDVisibility?(remaining != nil)
        refreshServer()
    }

    private func showEarlierDictation(_ pending: PendingDictation) {
        hudTask?.cancel()
        sessionID = pending.session
        activity = .transcribing
        statusMessage = "Earlier dictation is still processing"
        onHUDVisibility?(true)
    }

    /// Fork: `keepingAudio` stops a failed take instead of cancelling it and keeps
    /// the audio captured so far. Only an explicit cancel deletes it.
    private func resetSession(keepingAudio reason: String? = nil) {
        sessionID = UUID()
        hotkey.clearLatchedTake()
        microphoneStartTask?.cancel(); microphoneStartTask = nil
        uploadPipe?.cancel(); uploadPipe = nil
        uploadTask?.cancel(); uploadTask = nil
        destinationTask?.cancel(); destinationTask = nil
        appContextTask?.cancel(); appContextTask = nil
        stopRecordingTimer()
        if let reason { keepCapture(recorder.stopCapture(), reason: reason) } else { recorder.cancel() }
        outputMuter.restore()
        recorder.onChunk = nil
        insertionDestination = nil
        recordingListHint = nil
        recordingInputName = nil
        activeGeneration = nil
        recordingFeedback.reset()
    }

    private func failSession(_ message: String, cancelServer: Bool) {
        let generation = activeGeneration
        resetSession(keepingAudio: message)
        showError(message)
        if cancelServer, let generation { Self.cancelOnServer(generation) }
        refreshHistory()
    }

    /// Fork: finishes a failed take's files and keeps them. The next take's
    /// microphone waits for this teardown, as it does after a release.
    private func keepCapture(_ stopped: Task<CapturedAudio, Error>, reason: String) {
        let previous = recorderStopTask
        recorderStopTask = Task {
            _ = try? await previous?.value
            return try await stopped.value
        }
        Task { [weak self] in
            guard let audio = try? await stopped.value else { return }
            self?.keep(audio, reason: reason, generationID: nil)
        }
    }

    /// Fork: moves unconfirmed audio to Recovered Recordings off the main actor,
    /// then adds where it went to the error that `reason` is showing.
    private func keep(_ audio: CapturedAudio, reason: String, generationID: UUID?) {
        let note = generationID.map { "\(reason)\nServer take: \($0.uuidString)" } ?? reason
        Task { [weak self] in
            let location = await Task.detached(priority: .utility) { audio.retain(note: note) }.value
            guard let self else { return }
            let separator = reason.hasSuffix(".") ? " " : ". "
            let kept = "\(reason)\(separator)Recording kept in \((location.path as NSString).abbreviatingWithTildeInPath)."
            if errorMessage == reason { errorMessage = kept }
            if statusMessage == reason { statusMessage = kept }
            if lastDelivery == reason { lastDelivery = kept }
        }
    }

    /// Fork: deletes local audio off the main actor once it is no longer needed.
    private nonisolated static func discard(_ audio: CapturedAudio) {
        Task.detached(priority: .utility) { audio.cleanup() }
    }

    /// A create or microphone failure ends the take and rechecks the server.
    private func failStartup(_ error: Error) {
        serverHealth = nil
        serverStatusMessage = Self.connectionMessage(error)
        failSession(serverStatusMessage, cancelServer: true)
        refreshServer()
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty, !isBusy else { return }
        switch DictationClipboard.copy(lastTranscript, to: .general) {
        case .success: lastDelivery = "Copied to clipboard"; lastDeliveryStatus = .copied
        case .failure(let error): lastDelivery = error.localizedDescription; lastDeliveryStatus = .failed
        }
    }

    private func addPendingEntry(id: UUID, finish: FinishGenerationRequest) {
        pendingEntries.removeAll { $0.id == id }
        pendingEntries.append(PendingGenerationEntry(
            id: id, endpoint: preferences.endpoint,
            inferenceFrames: finish.inferenceFrames, originalFrames: finish.originalFrames, sealedAt: Date()))
        pendingStore.save(pendingEntries)
    }

    private func removePendingEntry(_ id: UUID) {
        pendingEntries.removeAll { $0.id == id }
        undeliveredResults.removeAll { $0.id == id }
        pendingStore.save(pendingEntries)
    }

    /// Surfaces takes that finished on the server while this app was not
    /// tracking them. Completed results are copy-only here: never inserted.
    private func reconcilePendingGenerations() async {
        guard !isReconcilingPending, !pendingEntries.isEmpty else { return }
        isReconcilingPending = true
        defer { isReconcilingPending = false }
        // Only the pointer goes. The audio stays on the server and in any local recovery folder.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let stale = pendingEntries.filter { $0.sealedAt < cutoff }
        for entry in stale { removePendingEntry(entry.id) }
        guard let connection = try? client() else { return }
        // Takes this session still owns deliver themselves; never offer them for copy.
        func isLive(_ id: UUID) -> Bool { pendingDictations.contains { $0.generationID == id } }
        // A connection change during the read drops or re-scopes entries; skip those.
        func isCurrent(_ entry: PendingGenerationEntry) -> Bool {
            entry.endpoint == preferences.endpoint && pendingEntries.contains { $0.id == entry.id }
        }
        for entry in pendingEntries where isCurrent(entry) && !isLive(entry.id) {
            guard let record = try? await connection.generation(entry.id),
                  isCurrent(entry), !isLive(entry.id) else { continue }
            switch record.status {
            case .completed:
                if record.delivery == nil {
                    if !undeliveredResults.contains(where: { $0.id == record.id }) {
                        undeliveredResults.append(record)
                    }
                } else { removePendingEntry(entry.id) }
            case .failed, .cancelled:
                removePendingEntry(entry.id)
            case .receiving:
                do {
                    _ = try await connection.finish(entry.id, value: FinishGenerationRequest(
                        inferenceFrames: entry.inferenceFrames, originalFrames: entry.originalFrames))
                } catch let ServerClientError.rejected(status, _) where (400..<500).contains(status) && ![401, 403, 408, 429].contains(status) {
                    // Auth failures may come from a credential the user has just
                    // replaced; they do not prove the speech is unrecoverable.
                    if isCurrent(entry) { removePendingEntry(entry.id) }
                } catch {}
            case .queued, .transcribing, .proofreading:
                break
            }
        }
    }

    /// Copies a result that finished while the app was closed. It never inserts.
    func copyUndeliveredResult(_ record: GenerationRecord) {
        switch DictationClipboard.copy(record.finalText, to: .general) {
        case .success:
            lastTranscript = record.finalText
            lastDelivery = "Copied to clipboard"
            lastDeliveryStatus = .copied
            removePendingEntry(record.id)
            Task { [weak self] in
                guard let connection = try? self?.client() else { return }
                try? await connection.delivery(record.id, receipt: DeliveryReceipt(
                    status: "copied", message: "Copied after relaunch"))
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func clearLastTranscript() {
        guard !isBusy else { return }
        continuationAnchors.removeAll()
        lastTranscript = ""; lastTranscriptionSeconds = nil; lastAudioSeconds = nil
        lastDelivery = ""; lastDeliveryStatus = .none; errorMessage = nil; activity = .idle
        recordingFeedback.reset()
    }

    func dismissFeedback() {
        guard !isBusy else { return }
        hudTask?.cancel()
        recordingFeedback.reset()
        onHUDVisibility?(false)
        if activity == .success { activity = .idle }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        wisprFlowPrepareTask?.cancel(); wisprFlowImportTask?.cancel()
        wisprFlowMaterializationTask?.cancel()
        wisprFlowPrepareGate?.cancel(waitForWorker: true)
        wisprFlowPrepareGate = nil
        for reader in wisprFlowActiveReaders.values { reader.close() }
        wisprFlowActiveReaders.removeAll()
        wisprFlowReader?.close()
        wisprFlowReader = nil
        stopShortcutCheck()
        // Quitting the client cancels an incomplete recording. A sealed server
        // generation remains independently owned and may complete in history.
        // Fork: its local audio is kept; if quitting outruns the move, the next
        // launch recovers it from Active Recordings.
        let generation = activeGeneration
        resetSession(keepingAudio: "The app quit during this take.")
        if let generation { Self.cancelOnServer(generation) }
        recorder.closeReadyInput() // Fork
        stopPendingDictations()
        monitorTask?.cancel(); refreshTask?.cancel(); hudTask?.cancel(); permissionTask?.cancel()
        configuration.stopWatching()
        subscriptions.removeAll()
        audioDevices.stop(); hotkey.stop(); continuationAnchors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        try? FileManager.default.removeItem(at: TranscriberTemporaryDirectory.url.appendingPathComponent("Transcriber-remote-preview"))
    }

    private func bindServices() {
        audioDevices.onChange = { [weak self] devices, defaultUID in
            self?.microphones.update(devices: devices, systemDefaultUID: defaultUID)
            self?.updateReadyMicrophone() // Fork: a reconnected device can keep its UID but not its ID.
        }
        // Fork: preferences publish before they change; read them on the next turn.
        microphones.objectWillChange.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateReadyMicrophone() }.store(in: &subscriptions)
        recorder.onLevel = { [weak self] level in
            guard let self, isCapturing else { return }
            recordingFeedback.append(level)
        }
        recorder.onVoice = { [weak self] in
            guard let self, isCapturing else { return }
            lastVoiceAt = ProcessInfo.processInfo.systemUptime
        }
        recorder.onInterruption = { [weak self] message in self?.salvageDictation(reason: message) }
        hotkey.onStatusChange = { [weak self] in self?.isHotkeyActive = $0 }
        hotkey.onPress = { [weak self] in
            guard let self else { return false }
            if isCheckingShortcut {
                appendShortcutCheck("Shortcut recognized. Recording was intentionally skipped.")
                // No take started, so a double-tap monitor must not latch.
                return false
            }
            // Fork: the key pressed to add a dictation key never starts a take.
            if isAddingShortcut { return false }
            return beginDictation(isTest: false)
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold released."); return }
            if isAddingShortcut { return }
            if !isTestSession { finishDictation() }
        }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold cancelled; microphone stayed off.") }
            else if canCancelWithEscape { cancelDictation() }
            else if !isBusy { dismissFeedback() }
        }
    }

    /// Returns whether a take actually started. A double-tap monitor latches
    /// only on true, so a rejected start cannot leave a phantom recording.
    @discardableResult
    private func beginDictation(isTest: Bool) -> Bool {
        guard !isCapturing, !isShuttingDown else { return false }
        stopShortcutCheck()
        guard isServerReady else { showError(serverStatusMessage); refreshServer(); return false }
        guard permissions.microphone else { showError("Allow microphone access, then try again."); return false }
        guard let input = microphones.resolution.device, let deviceID = audioDevices.deviceID(for: input.uid) else {
            showError("No microphone is available. Connect an input and try again."); return false
        }
        hudTask?.cancel(); errorMessage = nil
        // Confirmed cursor moves matter only to takes that overlap them.
        if pendingDictations.isEmpty { insertionRebases.removeAll() }
        sessionID = UUID()
        let current = sessionID
        isTestSession = isTest
        recordingClipboardChangeCount = NSPasteboard.general.changeCount
        insertionDestination = nil
        recordingInputName = input.name
        recordingFeedback.reset()
        activity = .starting
        if muteOutputWhileRecording { outputMuter.mute() }
        if !isTest {
            let capture = TextInserter.beginDestinationCapture()
            destinationTask = capture
            Task { [weak self] in
                let destination = await capture.value
                guard let self, sessionID == current, isCapturing else { return }
                insertionDestination = destination
                prepareContinuation(for: destination.target.map(DictationDestination.field))
            }
            // Fork: the apps around the take. The reader runs off the main actor.
            appContextTask = Task { await FocusContextReader.startContext() }
        } else { prepareContinuation(for: .test) }
        // Fork: the press-time snapshots above stay synchronous. The microphone
        // start and then the server create are queued next, and the HUD and its
        // status text wait for a later main-actor turn. The server creates the
        // take while the microphone starts, not before it; the pipe holds the
        // audio captured until the upload knows the generation ID.
        let pipe = AudioChunkPipe { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if sessionID == current, isCapturing {
                    failSession(error.localizedDescription, cancelServer: true)
                }
            }
        }
        uploadPipe = pipe
        recorder.onChunk = { pipe.append($0) }
        microphoneStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == current { microphoneStartTask = nil } }
            do {
                // A released take owns its teardown. Never let its asynchronous
                // stop consume the new microphone request.
                if let recorderStopTask { _ = try? await recorderStopTask.value }
                guard sessionID == current, activity == .starting, !Task.isCancelled else { return }
                // Fork: always capture the original audio. The created record's
                // own setting decides whether the upload sends it.
                try await recorder.start(deviceID: deviceID, preserveOriginalAudio: true,
                                         inferenceChannels: microphones.inferenceChannelRequest(for: input)) // Fork
                guard sessionID == current, activity == .starting, !Task.isCancelled else { return }
                // Fork: the minimum-length check and the timer count from here,
                // the captured audio, not from the microphone's startup.
                recordingStart = ProcessInfo.processInfo.systemUptime
                // Listening means the microphone is live, even if the create
                // has not returned. Finishing waits for it.
                activity = .recording
                statusMessage = "Listening"
                announceOutcome("Listening", .start)
                startRecordingTimer()
            } catch is CancellationError {
            } catch AudioRecordingError.cancelled {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                failStartup(error)
            }
        }
        let generation = Task { [weak self] () async throws -> StartedGeneration in
            guard let self else { throw CancellationError() }
            let connection = try client()
            let created = try await connection.create(.init(requestID: current,
                device: .init(id: preferences.deviceID, name: preferences.deviceName), mode: isTest ? .test : .dictation))
            guard created.status == .receiving else { throw ServerClientError.invalidResponse }
            if sessionID == current { sharedPreferences = created.settings }
            return StartedGeneration(id: created.id, client: connection,
                                     preserveOriginal: created.settings.preferences.keepOriginalAudio)
        }
        activeGeneration = generation
        uploadTask = Task { [weak self] in
            let started: StartedGeneration
            do { started = try await generation.value }
            catch {
                // The microphone may already be live, so fail as a startup error.
                if !(error is CancellationError), let self, sessionID == current, isCapturing, !Task.isCancelled {
                    failStartup(error)
                }
                throw error
            }
            try Task.checkCancellation()
            do {
                return try await started.client.upload(pipe, to: started.id, preserveOriginal: started.preserveOriginal)
            } catch {
                if let self, sessionID == current, isCapturing, !Task.isCancelled {
                    failSession(Self.connectionMessage(error), cancelServer: true)
                }
                throw error
            }
        }
        Task { [weak self] in
            guard let self, sessionID == current, isCapturing else { return }
            if activity == .starting { statusMessage = "Starting microphone…" }
            onHUDVisibility?(true)
        }
        return true
    }

    /// Interruption path: a lock, sleep, or lost microphone ends the take through
    /// the normal seal and delivers to the clipboard only. The captured insertion
    /// target cannot be trusted after the Mac was away.
    /// Fork: checks the take itself and never calls cancelDictation(), which
    /// deletes the take. A take too short to seal keeps its audio through failSession.
    private func salvageDictation(reason: String) {
        guard isCapturing else { return }
        guard activity == .recording, ProcessInfo.processInfo.systemUptime - recordingStart >= 0.25 else {
            failSession(reason, cancelServer: true); return
        }
        statusMessage = "Saving interrupted recording…"
        finishDictation(salvaged: true)
    }

    private func finishDictation(automaticStop: AutomaticStop? = nil, salvaged: Bool = false) {
        guard isCapturing else { return }
        // A take ended by the duration cap or by silence must not leave a
        // double-tap latch behind, matching the failure and cancel paths.
        hotkey.clearLatchedTake()
        recorder.stopAcceptingAudio()
        outputMuter.restore()
        guard activity == .recording else { cancelDictation(); return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        destinationTask?.finish()
        guard releasedAt - recordingStart >= 0.25 else { cancelDictation(); return }
        guard let generation = activeGeneration, let uploadTask, let uploadPipe else {
            failSession("This recording has no server session.", cancelServer: true); return
        }
        stopRecordingTimer(); resetLevels()
        recordingFeedback.finish(automaticStop: automaticStop)
        activity = .transcribing
        statusMessage = "Finishing upload…"
        hudProgressText = "Uploading"
        let current = sessionID
        let test = isTestSession
        let capturedDestination = insertionDestination
        let clipboardCount = recordingClipboardChangeCount
        let pending = PendingDictation(session: current, generation: generation, upload: uploadTask,
                                       pipe: uploadPipe, destination: destinationTask, appContext: appContextTask)
        pending.restedSinceRelease = salvaged
        // Usually known at release, so a later take can continue a list in another field.
        let knownDestination: InsertionDestination? = test || salvaged ? .clipboard : capturedDestination
        pending.target = knownDestination.map { Self.resolve($0, isTest: test, releasedAt: releasedAt) }
        pendingDictations.append(pending)
        activeGeneration = nil; self.uploadTask = nil; self.uploadPipe = nil
        destinationTask = nil; appContextTask = nil; insertionDestination = nil; recordingListHint = nil; recordingInputName = nil
        recorder.onChunk = nil
        let stopped = recorder.stopCapture()
        recorderStopTask = stopped
        let precedingDelivery = deliveryTail
        let task = Task { [weak self] in
            guard let self else { return }
            // Fork: the local audio lives until the server confirms the seal.
            var capturedAudio: CapturedAudio?
            var generationID: UUID?
            defer {
                if pending.resolved, let id = pending.generationID { removePendingEntry(id) }
                pending.settle()
                pendingDictations.removeAll { $0 === pending }
                if pendingDictations.isEmpty {
                    deliveryTail = nil
                    applyConfiguration(configuration.configuration)
                }
            }
            do {
                let audio = try await stopped.value
                capturedAudio = audio
                try Task.checkCancellation()
                pending.pipe.finish()
                // Fork: the upload waits for the create, so a take finished
                // while connecting still seals once its server record exists.
                var finish = try await pending.upload.value
                let started = try await pending.generation.value
                let id = started.id, connection = started.client
                generationID = id
                pending.generationID = id
                try Task.checkCancellation()
                let target: (destination: InsertionDestination, anchor: DictationDestination?)
                if let known = pending.target { target = known }
                else {
                    target = Self.resolve(await pending.destination?.value ?? .clipboard, isTest: test, releasedAt: releasedAt)
                    pending.target = target
                }
                let resolved = target.destination, anchor = target.anchor
                // Queued takes must not both extend the last delivered list snapshot.
                // An earlier take that is unresolved or shares this anchor suppresses it.
                let sharesEarlierAnchor = pendingDictations.prefix { $0 !== pending }
                    .contains { earlier in earlier.target.map { $0.anchor == anchor } ?? true }
                finish.continuationID = sharesEarlierAnchor ? nil : anchor.flatMap { self.continuation(for: $0)?.generationID }
                try Task.checkCancellation()
                pending.sealed = true // The server may accept a seal whose response is interrupted.
                if !test { addPendingEntry(id: id, finish: finish) }
                var result: GenerationRecord
                do { result = try await connection.finish(id, value: finish) }
                catch let ServerClientError.rejected(status, message) where (400..<500).contains(status) && ![408, 429].contains(status) {
                    pending.sealed = false // The server answered without sealing, so cancel promptly.
                    throw ServerClientError.rejected(status, message)
                }
                // Fork: the server confirmed the seal, so its copy is durable.
                // Only now delete the local copy, off the main actor.
                Self.discard(audio)
                capturedAudio = nil
                try Task.checkCancellation()
                if !result.status.isTerminal {
                    result = try await connection.events(id) { [weak self] record in
                        await self?.applyProgress(record, session: current)
                    }
                }
                try Task.checkCancellation()
                guard result.status == .completed else {
                    pending.resolved = true // Terminal on the server; visible in History.
                    throw ServerClientError.rejected(422, result.error ?? "The server could not process this recording.")
                }
                // Processing and uploads overlap. Clipboard/paste transactions
                // remain ordered and each keeps its original destination.
                await precedingDelivery?.value
                await waitForCaptureRelease()
                try Task.checkCancellation()
                pending.delivering = true
                // Fork: a lock or sleep before this point sends the words to the clipboard only.
                let deliveryDestination: InsertionDestination = pending.restedSinceRelease ? .clipboard : rebasedDestination(resolved)
                // Fork: read focus as delivery starts, off the main actor, and send
                // it after the receipt. Neither step holds up this take or later ones.
                let deliveryFocus = pending.appContext.map { _ in Task { await FocusContextReader.snapshot() } }
                let receipt = await deliver(result, to: deliveryDestination, anchor: anchor, isTest: test,
                                            clipboardCount: clipboardCount, session: current,
                                            hasRested: { pending.restedSinceRelease })
                try Task.checkCancellation()
                do { try await connection.delivery(id, receipt: receipt) }
                catch { continuationAnchors.removeAll { $0.generationID == id } }
                if let start = pending.appContext, let deliveryFocus {
                    Task {
                        var context = await start.value
                        context.delivery = await deliveryFocus.value
                        guard context != AppContext() else { return }
                        do { try await connection.appContext(id, context: context) }
                        catch {
                            // Best effort: the take keeps its outcome. Never log the context itself.
                            Logger(subsystem: Bundle.main.bundleIdentifier ?? "transcriber", category: "app-context")
                                .notice("App context for \(id, privacy: .public) was not stored: \(String(describing: type(of: error)), privacy: .public)")
                        }
                    }
                }
                try Task.checkCancellation()
                // Other takes can change the shared last-delivery state during the receipt request.
                let delivered = DictationDeliveryStatus(rawValue: receipt.status) ?? .failed
                if sessionID == current {
                    hudProgressText = nil
                    activity = delivered == .failed ? .failed : .success
                    dismissHUDAfter(seconds: delivered.needsAttention ? 4 : 1.7)
                    let outcomeSound: OutcomeFeedback.Sound =
                        switch delivered {
                        case .inserted, .tested, .listUpdated: .success
                        case .copied, .unconfirmed: .attention
                        case .failed, .none: .failure
                        }
                    announceOutcome(receipt.message ?? delivered.hudLabel, outcomeSound)
                } else if delivered.needsAttention {
                    // A newer take owns the HUD and will replace this result.
                    errorMessage = "Earlier dictation: \(receipt.message ?? delivered.hudLabel)"
                    if let errorMessage { announceOutcome(errorMessage, .attention) }
                }
                pending.resolved = true
                refreshServer()
            } catch {
                pending.upload.cancel(); pending.pipe.cancel(); pending.destination?.cancel(); pending.appContext?.cancel()
                if !pending.sealed {
                    pending.resolved = true
                    pending.cancelOnServer()
                }
                // Fork: audio the server has not confirmed is kept, unless the
                // user explicitly cancelled this take.
                let unconfirmed = capturedAudio
                capturedAudio = nil
                if let unconfirmed, pending.discardsAudio { Self.discard(unconfirmed) }
                let kept = pending.discardsAudio ? nil : unconfirmed
                guard !Task.isCancelled else {
                    if let kept { keep(kept, reason: "The take stopped before the server confirmed it.", generationID: generationID) }
                    return
                }
                if let clientError = error as? ServerClientError, case .processingTimedOut = clientError {
                    // Not a failure: the seal is confirmed and the pending entry stays,
                    // so the relaunch reconcile path offers the result for copy.
                    if sessionID == current {
                        activity = .idle
                        statusMessage = "Still processing on the server"
                        hudProgressText = nil
                        dismissHUDAfter(seconds: 4)
                    }
                    refreshHistory()
                    return
                }
                let message: String
                if sessionID == current {
                    if error is URLError { serverHealth = nil; serverStatusMessage = Self.connectionMessage(error) }
                    message = Self.connectionMessage(error)
                    showError(message)
                } else {
                    message = "Earlier dictation failed: \(Self.connectionMessage(error))"
                    errorMessage = message
                    lastDelivery = message
                    lastDeliveryStatus = .failed
                    // An older job may fail while the microphone or a newer
                    // result owns the HUD. Keep that live activity intact.
                    if !activity.isBusy { showError(message) } else { announceOutcome(message, .failure) }
                }
                if let kept { keep(kept, reason: message, generationID: generationID) }
                refreshHistory()
            }
        }
        pending.task = task
        // Even a failed/cancelled middle take must preserve the ordering link
        // to earlier deliveries for every later take.
        // Fork: wait for this take to settle rather than for its task, so a
        // cancelled take still awaiting its create does not hold later takes.
        deliveryTail = Task {
            await precedingDelivery?.value
            await pending.waitUntilSettled()
        }
    }

    private static func resolve(_ destination: InsertionDestination, isTest: Bool,
                                releasedAt: TimeInterval) -> (destination: InsertionDestination, anchor: DictationDestination?) {
        var resolved = destination
        if let target = destination.target, !InsertionCapturePolicy.permitsInsertion(capturedAt: target.capturedAt, releasedAt: releasedAt) {
            resolved = .clipboard
        }
        return (resolved, isTest ? .test : resolved.target.flatMap { $0.selection == nil ? nil : .field($0) })
    }

    private func applyProgress(_ generation: GenerationRecord, session: UUID) {
        guard sessionID == session, !isCapturing else { return }
        switch generation.status {
        case .receiving: statusMessage = "Finishing upload…"; hudProgressText = "Uploading"
        case .queued: statusMessage = "Queued on server…"; hudProgressText = "Queued"
        case .transcribing: statusMessage = "Transcribing on server…"; hudProgressText = "Transcribing"
        case .proofreading: statusMessage = "Proofreading on server…"; hudProgressText = "Proofreading"
        case .completed: statusMessage = "Preparing result…"; hudProgressText = "Preparing"
        case .failed, .cancelled: statusMessage = generation.error ?? "Processing stopped"; hudProgressText = nil
        }
    }

    private func deliver(_ record: GenerationRecord, to destination: InsertionDestination,
                         anchor: DictationDestination?, isTest: Bool, clipboardCount: Int,
                         session: UUID, hasRested: @escaping () -> Bool) async -> DeliveryReceipt {
        var transcript = record.previewText.isEmpty ? record.finalText : record.previewText
        let message: String
        let deliveryStatus: DictationDeliveryStatus
        let status: String
        if isTest {
            rememberContinuation(record, at: .test)
            message = "Test complete. Nothing was pasted."
            deliveryStatus = .tested
            status = record.finalText.isEmpty ? "No speech detected" : "Ready to copy"
        } else if record.insertionText.isEmpty {
            if record.continuation == nil && record.previewText.isEmpty {
                message = "No speech detected"; deliveryStatus = .none
            } else if let confirmed = TextInserter.unchangedAnchor(destination.target) {
                rememberContinuation(record, at: .field(confirmed))
                message = "List updated. Nothing was pasted."; deliveryStatus = .listUpdated
            } else {
                message = "List state unchanged: the original cursor could not be confirmed."
                deliveryStatus = .unconfirmed
            }
            status = message
        } else {
            if sessionID == session { activity = .delivering; statusMessage = "Inserting at your cursor…"; hudProgressText = "Inserting" }
            let inserter = TextInserter()
            let outcome = await inserter.deliver(record.insertionText, copying: record.finalText,
                                                  to: destination, clipboardUnchangedSince: clipboardCount,
                                                  waitUntilReady: { await self.waitForCaptureRelease() },
                                                  isCaptureActive: { self.isHoldingCapture },
                                                  hasRested: hasRested)
            guard !Task.isCancelled else { return DeliveryReceipt(status: "failed", message: "Delivery cancelled") }
            if let anchor { continuationAnchors.removeAll { $0.destination == anchor } }
            switch outcome {
            case .inserted:
                if let target = inserter.confirmedAnchor {
                    if let original = destination.target {
                        insertionRebases.inserted(at: original, confirmed: target)
                    }
                    rememberContinuation(record, at: .field(target))
                }
                message = "Inserted at your cursor"; deliveryStatus = .inserted; status = "Inserted"
            case .copied(let reason):
                transcript = record.finalText; message = reason; deliveryStatus = .copied; status = "Copied"
            case .unconfirmed(let backup):
                transcript = record.finalText
                message = backup ? "Insertion unconfirmed. Copied to clipboard if needed." : "Insertion unconfirmed. Your words are here to copy."
                deliveryStatus = .unconfirmed; status = "Check insertion"
            case .failed(let reason):
                transcript = record.finalText; message = reason; deliveryStatus = .failed; status = "Ready to copy"
            }
        }
        lastTranscript = transcript
        lastAudioSeconds = record.audioSeconds
        lastTranscriptionSeconds = (record.speech?.processingSeconds ?? 0) + (record.proofreading?.processingSeconds ?? 0)
        lastDelivery = message
        lastDeliveryStatus = deliveryStatus
        if sessionID == session { statusMessage = status }
        return DeliveryReceipt(status: deliveryStatus.rawValue, message: message)
    }

    private func rebasedDestination(_ destination: InsertionDestination) -> InsertionDestination {
        guard let target = destination.target else { return destination }
        return .field(insertionRebases.destination(for: target) { TextInserter.unchangedAnchor($0) != nil })
    }

    /// Delivery never overlaps a hold, including a press still inside its acceptance delay.
    private var isHoldingCapture: Bool { isCapturing || hotkey.isHoldInProgress }

    private func waitForCaptureRelease() async {
        while isHoldingCapture, (try? await Task.sleep(for: .milliseconds(50))) != nil {}
    }

    private func stopPendingDictations() {
        for pending in pendingDictations {
            pending.cancel()
            if !pending.sealed {
                // Sealed entries stay for the next launch.
                if let id = pending.generationID { removePendingEntry(id) }
                pending.cancelOnServer()
            }
        }
        pendingDictations.removeAll()
        deliveryTail = nil
        insertionRebases.removeAll()
    }

    private func continuation(for destination: DictationDestination) -> ContinuationAnchor? {
        let now = ProcessInfo.processInfo.systemUptime
        continuationAnchors.removeAll { now < $0.timestamp || now - $0.timestamp >= 15 * 60 }
        return continuationAnchors.last { $0.destination == destination }
    }

    private func prepareContinuation(for destination: DictationDestination?) {
        if let destination, let list = continuation(for: destination)?.continuation.list {
            recordingListHint = list.style == .numbered ? "Continuing at item \(list.nextNumber)" : "Continuing your list"
        } else { recordingListHint = nil }
    }

    private func rememberContinuation(_ record: GenerationRecord, at destination: DictationDestination) {
        continuationAnchors.removeAll { $0.destination == destination }
        guard let continuation = record.continuation else { return }
        continuationAnchors.append(.init(destination: destination, generationID: record.id, continuation: continuation,
                                         timestamp: ProcessInfo.processInfo.systemUptime))
        continuationAnchors = Array(continuationAnchors.suffix(8))
    }

    private func announceOutcome(_ message: String, _ sound: OutcomeFeedback.Sound?) {
        OutcomeFeedback.announce(message, sound: sound, soundsEnabled: dictationSoundsEnabled)
    }

    private func showError(_ message: String) {
        hudProgressText = nil
        recordingFeedback.reset()
        activity = .failed; errorMessage = message; statusMessage = message
        announceOutcome(message, .failure)
        onHUDVisibility?(true)
        dismissHUDAfter(seconds: 4)
    }

    private func dismissHUDAfter(seconds: Double) {
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !activity.isBusy else { return }
            // A newer take's result was shown; return the HUD to earlier work.
            if let earlier = pendingDictations.last { showEarlierDictation(earlier); return }
            onHUDVisibility?(false)
            recordingFeedback.reset()
            if activity == .success { activity = .idle; statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage }
        }
    }

    private func installLifecycleObservers() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.refreshPermissions(); self?.refreshServer() }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willPowerOffNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.restForSystem() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.restForSystem() }
        }
    }

    private func restForSystem() {
        stopShortcutCheck()
        // Salvage a live take and leave sealed takes running. Every take that has
        // not delivered yet goes to the clipboard after wake.
        if isCapturing { salvageDictation(reason: "Recording interrupted while your Mac was away.") }
        for pending in pendingDictations { pending.restedSinceRelease = true }
        continuationAnchors.removeAll()
    }
    func refreshPermissions() {
        let current = PermissionSnapshot.capture()
        if current != permissions { permissions = current }
        audioDevices.refresh()
        updateReadyMicrophone() // Fork
        if permissions.canListenForHotkey {
            isHotkeyActive = hotkey.start()
        } else {
            hotkey.stop()
            isHotkeyActive = false
        }
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "transcriber", category: "permissions").notice(
            "Permissions refreshed: microphone=\(current.microphone), accessibility=\(current.accessibility), inputMonitoring=\(current.inputMonitoring), hotkey=\(self.isHotkeyActive)"
        )
    }

    /// Fork: keeps the next take's microphone running between takes while
    /// "Keep microphone ready" is on. The recorder ignores repeated targets.
    private func updateReadyMicrophone() {
        guard !isShuttingDown else { return }
        let target: WarmInputTarget
        if !microphones.keepMicrophoneReady {
            target = .off("Keep microphone ready is off")
        } else if !permissions.microphone {
            target = .off("microphone access is not allowed")
        } else if let device = microphones.resolution.device, let id = audioDevices.deviceID(for: device.uid) {
            target = .input(id, device)
        } else {
            target = .off("no microphone is available")
        }
        recorder.keepReady(target)
    }

    func requestMicrophone() {
        if permissions.microphone {
            PermissionManager.openMicrophoneSettings()
            return
        }
        Task {
            _ = await PermissionManager.requestMicrophone()
            refreshPermissions()
        }
    }

    func requestAccessibility() {
        if permissions.accessibility { PermissionManager.openAccessibilitySettings() }
        else { PermissionManager.requestAccessibility() }
        retryPermissions()
    }

    func requestInputMonitoring() {
        if permissions.inputMonitoring { PermissionManager.openInputMonitoringSettings() }
        else { PermissionManager.requestInputMonitoring() }
        retryPermissions()
    }

    func startShortcutCheck() {
        guard !isBusy, !isCheckingShortcut else { return }
        refreshPermissions()
        shortcutCheckStarted = ProcessInfo.processInfo.systemUptime
        shortcutCheckEntries = []
        isCheckingShortcut = true
        hotkey.onDiagnostic = { [weak self] message in self?.appendShortcutCheck(message) }
        hotkey.requireFreshHold()
        appendShortcutCheck("Checking \(shortcuts.map(\.title).orList) for 60 seconds. The microphone stays off.")
        appendShortcutCheck("Listener: \(isHotkeyActive ? "enabled" : "unavailable"); Accessibility: \(permissions.accessibility); Input Monitoring: \(permissions.inputMonitoring).")
        shortcutCheckTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.stopShortcutCheck()
        }
    }

    func stopShortcutCheck() {
        guard isCheckingShortcut else { return }
        // Reset before leaving check mode: a delayed callback must never start
        // the microphone just because this check timed out during a held key.
        hotkey.requireFreshHold()
        appendShortcutCheck("Check ended. No audio was recorded.")
        hotkey.onDiagnostic = nil
        isCheckingShortcut = false
        shortcutCheckTask?.cancel()
        shortcutCheckTask = nil
    }

    /// Fork: listens for the next key pressed in a Transcriber window and adds
    /// it to the dictation keys. Escape or 60 s without a key cancels. The
    /// press never reaches the window and never starts a take.
    func beginAddingShortcut() {
        guard !isBusy, !isAddingShortcut else { return }
        stopShortcutCheck()
        isAddingShortcut = true
        shortcutCapture = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.captureShortcut(event) ?? false }
            return used ? nil : event
        }
        shortcutCaptureTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.finishAddingShortcut()
        }
    }

    /// Ends key capture and adds `key` when it is not listed yet.
    func finishAddingShortcut(_ key: HoldKey? = nil) {
        guard isAddingShortcut else { return }
        // Same reset as a shortcut check: a key still held when capture ends
        // must not start a take.
        hotkey.requireFreshHold()
        isAddingShortcut = false
        if let shortcutCapture { NSEvent.removeMonitor(shortcutCapture) }
        shortcutCapture = nil
        shortcutCaptureTimeout?.cancel()
        shortcutCaptureTimeout = nil
        if let key, !shortcuts.contains(key) { shortcuts.append(key) }
    }

    /// Returns true when capture uses the event, so the window never sees it.
    private func captureShortcut(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 {
            finishAddingShortcut()
            return true
        }
        guard let key = HoldKey(keyCode: event.keyCode) else { return false }
        if event.type == .keyDown {
            // isARepeat is defined only for key events.
            if event.isARepeat { return true }
        } else if !(event.cgEvent.map { key.isDown(in: $0.flags) } ?? false) {
            // A modifier counts on its press, not its release.
            return false
        }
        finishAddingShortcut(key)
        return true
    }

    private func appendShortcutCheck(_ message: String) {
        guard isCheckingShortcut else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - shortcutCheckStarted
        let context = NSApp.isActive ? "Transcriber" : "background"
        shortcutCheckEntries.append(String(format: "%.2fs", elapsed) + " [\(context)] " + message)
        shortcutCheckEntries = Array(shortcutCheckEntries.suffix(16))
        shortcutCheckText = shortcutCheckEntries.joined(separator: "\n")
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - self.recordingStart
                self.recordingFeedback.updateElapsed(elapsed)
                if elapsed >= TimeInterval(TranscriberAPI.maximumRecordingSeconds) {
                    self.finishDictation(automaticStop: .durationLimit)
                } else if now - max(self.recordingStart, self.lastVoiceAt) >= LifecyclePolicy.silenceStopSeconds {
                    self.finishDictation(automaticStop: .silence)
                }
            }
        }
        timer.tolerance = 0.025
        recordingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func resetLevels() {
        recordingFeedback.clearLevels()
    }

    private func retryPermissions() {
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            for _ in 0..<30 {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard let self else { return }
                refreshPermissions()
                if allPermissionsGranted { return }
            }
        }
    }

    private func updateLoginItem() {
        guard !updatingLogin else { return }
        updatingLogin = true
        defer { updatingLogin = false }
        loginItemError = nil
        let status = SMAppService.mainApp.status
        if launchAtLogin, status == .enabled { return }
        if launchAtLogin, status == .requiresApproval {
            loginItemError = "Allow Transcriber in System Settings → General → Login Items to finish enabling this preference."
            return
        }
        // A rebuilt accessory app may report .notFound even though login is
        // already off. Do not attempt to unregister an absent service.
        if !launchAtLogin, status != .enabled, status != .requiresApproval { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                loginItemError = "Allow Transcriber in System Settings → General → Login Items to finish enabling this preference."
            }
        } catch {
            // Keep the desired setting consistent between UI and JSON. A denied
            // OS operation must not trigger file rollback/retry feedback loops.
            loginItemError = "Couldn’t update launch at login: \(error.localizedDescription)"
        }
    }


}
