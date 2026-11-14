import AppKit
import Combine
import InlayAPI
import InlayCore
import ServiceManagement

private enum DictationDestination: Equatable {
    case test
    case field(InsertionTarget)
}

/// The desktop never owns a durable generation or a model process. A take has
/// one accepted server generation, one bounded upload, and at most one delivery.
enum InsertionMode {
    case insertion
    case clipboardOnly
    case unavailable
}

@MainActor
final class InlayController: ObservableObject {
    @Published var activity: DictationActivity = .idle
    let recordingFeedback = RecordingFeedback()
    @Published var recordingListHint: String?
    @Published private(set) var recordingInputName: String?
    @Published var lastTranscript = ""
    @Published var lastTranscriptionSeconds: Double?
    @Published var lastAudioSeconds: Double?
    @Published var lastDelivery = ""
    @Published private(set) var lastDeliveryStatus: DictationDeliveryStatus = .none
    @Published private(set) var attentionPresented = false
    @Published var errorMessage: String?
    @Published var permissions: PermissionSnapshot
    @Published var isHotkeyActive = false
    @Published private(set) var isCheckingShortcut = false
    @Published private(set) var shortcutCheckText = ""
    @Published var shortcut: HoldKey = .rightOption {
        didSet {
            if shortcut != oldValue { stopShortcutCheck() }
            if !applyingConfiguration { configuration.update { $0.holdKey = shortcut.rawValue } }
            hotkey.key = shortcut
        }
    }
    @Published var customTriggerKeyCode: Int? {
        didSet {
            if customTriggerKeyCode != oldValue { stopShortcutCheck() }
            if !applyingConfiguration {
                let code = customTriggerKeyCode
                configuration.update { $0.customTriggerKeyCode = code }
            }
            hotkey.customKeyCode = customTriggerKeyCode.map { CGKeyCode($0) }
        }
    }
    @Published var activationMode: HotkeyActivationMode = .hold {
        didSet {
            guard activationMode != oldValue else { return }
            if !applyingConfiguration { configuration.update { $0.activationMode = activationMode.rawValue } }
            hotkey.mode = activationMode
        }
    }
    @Published var launchAtLogin = true {
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
    @Published var preserveClipboard = false {
        didSet {
            if !applyingConfiguration { configuration.update { $0.preserveClipboard = preserveClipboard } }
        }
    }
    @Published var statusMessage = "Connecting to server…"
    @Published private(set) var hudProgressText: String?
    @Published private(set) var serverHealth: ServerHealth?
    @Published private(set) var serverStatusMessage = "Connecting…"
    @Published private(set) var isCheckingServer = false
    @Published private(set) var isSavingPreferences = false
    @Published private(set) var sharedPreferences: PreferencesSnapshot?
    @Published private(set) var storageUsage: StorageUsage?
    let modelDownloads = ModelDownloadManager()
    let localServer = LocalServerManager()
    @Published private(set) var generations: [GenerationSummary] = []
    @Published private(set) var generationDetail: GenerationRecord?
    @Published private(set) var generationDetailFailedID: UUID?
    private var detailTask: Task<Void, Never>?
    @Published private(set) var undeliveredResults: [GenerationRecord] = []
    @Published private(set) var devices: [DeviceSummary] = []
    @Published private(set) var legacyEnrollmentClosed = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var hasMoreHistory = false
    @Published private(set) var historySourceFilter = "all"
    private var historyCursor: String?
    private(set) lazy var wisprImport = WisprFlowImportDriver(
        makeClient: { [weak self] in
            guard let self else { throw CancellationError() }
            return try client()
        },
        isDictationBusy: { [weak self] in self?.isBusy ?? true },
        endpoint: { [weak self] in self?.preferences.endpoint ?? "" },
        onHistoryChanged: { [weak self] isCurrentRevision in
            guard let self else { return }
            if isCurrentRevision, historySourceFilter != "wispr-flow" {
                setHistorySourceFilter("wispr-flow")
            } else {
                // A cancelled run can still have committed on the server.
                // Refresh the user's current view without changing its filter.
                refreshHistory()
            }
        }
    )
    let configuration: ConfigurationStore
    let microphones: MicrophonePreferencesStore
    let preferences: ClientPreferencesStore
    private let pendingStore: PendingGenerationsStore
    private var pendingEntries: [PendingGenerationEntry]
    private var connectionRevision = 0
    /// Client data directory; takes are spooled under its `recordings` folder.
    private let clientRoot: URL
    private var recoveryTask: Task<Void, Never>?
    @Published private(set) var savedRecordingCount = 0
    @Published private(set) var lastRecordingSavedLocally = false
    @Published private(set) var savedRecordingsNeedServerUpdate = false
    /// Finishes once captured audio is written and synchronized to the spool.
    private(set) var terminationDrain: Task<Void, Never>?
    /// Per-spool retry backoff for recovery uploads, keyed by spool ID.
    private var spoolRetries: [UUID: (failures: Int, nextAttempt: Date)] = [:]
    /// If storage refuses a discard, never re-open that spool in this process.
    private var failedDiscards: Set<UUID> = []

    var isRecording: Bool { activity == .recording }
    var isCapturing: Bool { activity.isCapturing }
    var recordingUsesClipboard: Bool { isCapturing && insertionDestination == .clipboard }
    var isBusy: Bool { activity.isBusy || !pendingDictations.isEmpty }
    var pendingDictationCount: Int { pendingDictations.count }
    var canCancelWithEscape: Bool { isCapturing && !hotkey.isHoldingFn }
    var triggerKeyTitle: String {
        if let customTriggerKeyCode, let title = HoldKey.customKeyTitle(CGKeyCode(customTriggerKeyCode)) {
            return title
        }
        return shortcut.title
    }
    var isServerReady: Bool { serverHealth?.ready == true && serverHealth?.apiVersion == InlayAPI.version }
    /// A configured Mac can keep dictation locally without a healthy connection.
    /// A known incompatible server is not an offline destination.
    var canStartDictation: Bool {
        isServerReady || (!preferences.token.isEmpty && (serverHealth == nil || serverHealth?.apiVersion == InlayAPI.version)
                          && (try? ServerEndpoint(preferences.endpoint)) != nil)
    }
    var canTest: Bool { isServerReady && permissions.microphone && microphones.resolution.device != nil && !isCapturing }
    var insertionMode: InsertionMode { Self.insertionMode(for: permissions) }
    static func insertionMode(for snapshot: PermissionSnapshot) -> InsertionMode {
        if snapshot.accessibility { return .insertion }
        if snapshot.inputMonitoring { return .clipboardOnly }
        return .unavailable
    }
    var selectedInputName: String { microphones.resolution.device?.name ?? "No microphone available" }
    var allPermissionsGranted: Bool { permissions.microphone && permissions.accessibility }
    var onHUDVisibility: ((Bool) -> Void)?
    var onShowWindow: (() -> Void)?

    private let recorder: AudioRecorder
    private let audioDevices: AudioDeviceStore
    private let serverClientFactory: (() throws -> ServerClient)?
    private let hotkey = HotkeyMonitor()
    private let outputMuter: SystemOutputMuter
    private var subscriptions: Set<AnyCancellable> = []
    private var applyingConfiguration = false
    private var recordingTimer: Timer?
    private var recordingStart: TimeInterval = 0
    private var recordingLimit = InlayAPI.maximumRecordingSeconds
    private var microphoneStartTask: Task<Void, Never>?
    private var recorderStopTask: Task<CapturedAudio, Error>?
    private var deliveryTail: Task<Void, Never>?
    private var insertionRebases = ConfirmedInsertionRebases<InsertionTarget>()
    /// Released takes in recording order. The newest may own the HUD via sessionID.
    @Published private var pendingDictations: [PendingDictation] = []
    private var uploadTask: Task<UploadOutcome, Error>?
    private var activeSpool: RecordingSpool?
    private var refreshTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var shortcutCheckTask: Task<Void, Never>?
    private var shortcutCheckStarted: TimeInterval = 0
    private var shortcutCheckEntries: [String] = []
    private var sessionID = UUID()
    private var activeGenerationID: UUID?
    private var activeClient: ServerClient?
    @MainActor
    private final class PendingDictation {
        let session: UUID
        /// The live generation, replaced if its upload fails and the spool is
        /// re-uploaded to a fresh one.
        var id: UUID?
        let client: ServerClient
        let upload: Task<UploadOutcome, Error>?
        let spool: RecordingSpool
        let destination: InsertionDestinationCapture?
        var task: Task<Void, Never>?
        var sealed = false
        var resolved = false
        /// Nil until the destination resolves; list continuation keys off its anchor.
        var target: (destination: InsertionDestination, anchor: DictationDestination?)?

        init(session: UUID, id: UUID?, client: ServerClient, upload: Task<UploadOutcome, Error>?,
             spool: RecordingSpool, destination: InsertionDestinationCapture?) {
            self.session = session; self.id = id; self.client = client; self.upload = upload
            self.spool = spool; self.destination = destination
        }

        /// Stops work but keeps the spool, so quitting never loses a take.
        func cancel() {
            task?.cancel(); upload?.cancel(); destination?.cancel()
        }
    }
    @Published private var insertionDestination: InsertionDestination?
    private var destinationTask: InsertionDestinationCapture?
    private var recordingClipboardChangeCount = 0
    private struct ContinuationAnchor {
        let destination: DictationDestination
        let generationID: UUID
        let continuation: DictationContinuation
        let timestamp: TimeInterval
    }
    private var continuationAnchors: [ContinuationAnchor] = []
    private var isTestSession = false
    private var sessionClipboardOnly = false
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
        outputMuter = SystemOutputMuter(
            recordURL: configuration.url.deletingLastPathComponent().appendingPathComponent("output-mute.json"))
        self.recorder = recorder ?? AudioRecorder()
        self.audioDevices = audioDevices ?? AudioDeviceStore()
        self.serverClientFactory = serverClient
        clientRoot = configuration.url.deletingLastPathComponent()
        preferences = ClientPreferencesStore(root: configuration.url.deletingLastPathComponent())
        let loadedPendingStore = PendingGenerationsStore(root: configuration.url.deletingLastPathComponent())
        pendingStore = loadedPendingStore
        pendingEntries = loadedPendingStore.load()
        microphones = MicrophonePreferencesStore(configuration: configuration)
        permissions = startServices ? PermissionSnapshot.capture()
            : PermissionSnapshot(microphone: false, accessibility: false, inputMonitoring: false)
        applyConfiguration(configuration.configuration)
        hotkey.key = shortcut
        microphones.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        preferences.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        configuration.$configuration.removeDuplicates().sink { [weak self] in self?.applyConfiguration($0) }.store(in: &subscriptions)
        guard startServices else { return }
        outputMuter.restorePersistedMute()
        Task { [weak self] in await self?.localServer.detect() }
        bindServices()
        self.audioDevices.start()
        installLifecycleObservers()
        refreshPermissions()
        // Capture files are temporary only; server history is never examined here.
        CapturedAudio.cleanupOrphans()
        try? FileManager.default.removeItem(at: InlayTemporaryDirectory.url.appendingPathComponent("Inlay-remote-preview"))
        hasInitialized = true
        updateLoginItem()
        refreshSavedRecordingCount()
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

    private func applyConfiguration(_ settings: InlayConfiguration) {
        guard !isBusy, !isShuttingDown else { return }
        applyingConfiguration = true
        if let key = HoldKey(rawValue: settings.holdKey), shortcut != key { shortcut = key }
        if let mode = HotkeyActivationMode(rawValue: settings.activationMode), activationMode != mode { activationMode = mode }
        if launchAtLogin != settings.launchAtLogin { launchAtLogin = settings.launchAtLogin }
        if muteOutputWhileRecording != settings.muteOutputWhileRecording { muteOutputWhileRecording = settings.muteOutputWhileRecording }
        if dictationSoundsEnabled != settings.dictationSoundsEnabled { dictationSoundsEnabled = settings.dictationSoundsEnabled }
        if customTriggerKeyCode != settings.customTriggerKeyCode { customTriggerKeyCode = settings.customTriggerKeyCode }
        if preserveClipboard != settings.preserveClipboard { preserveClipboard = settings.preserveClipboard }
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
        guard serverClientFactory != nil || !preferences.token.isEmpty else {
            // An empty profile cannot authenticate. Repeated health requests would
            // consume the server's failed-auth budget, including for other clients.
            let message = "Enter a server token in This Mac to connect"
            if serverHealth != nil { serverHealth = nil }
            if serverStatusMessage != message { serverStatusMessage = message }
            if !isBusy, activity == .idle, statusMessage != message { statusMessage = message }
            return
        }
        isCheckingServer = true
        let endpoint = preferences.endpoint
        let revision = connectionRevision
        defer { isCheckingServer = false }
        do {
            let connection = try client()
            let health = try await connection.health()
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            serverHealth = health
            serverStatusMessage = health.apiVersion != InlayAPI.version ? "Server API version is incompatible"
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
            }
            if refreshData { await refreshDevices() }
            await reconcilePendingGenerations(connection, endpoint: endpoint, revision: revision)
            if health.ready, health.apiVersion == InlayAPI.version, recoveryTask == nil,
               endpoint == preferences.endpoint, !isShuttingDown, !Task.isCancelled {
                // Keep health checks independent; cancel this endpoint-bound job on a switch or quit.
                recoveryTask = Task { [weak self] in
                    guard let self else { return }
                    defer { recoveryTask = nil }
                    await recoverSavedRecordings(connection, endpoint: endpoint, limit: health.supportedRecordingSeconds)
                }
            }
        } catch is CancellationError {
        } catch {
            guard endpoint == preferences.endpoint, !Task.isCancelled else { return }
            if let clientError = error as? ServerClientError,
               case .rejected(let status, _, let code) = clientError,
               status == 403, code == "enrollment_required", !isBusy,
               await enrollThisDevice() {
                refreshServer()
                return
            }
            serverHealth = nil
            serverStatusMessage = Self.connectionMessage(error)
            if !isBusy, activity == .idle { statusMessage = serverStatusMessage }
        }
    }

    func saveConnection(endpoint: String, token: String, deviceName: String) {
        guard !isBusy, !wisprImport.isImportRunning else { return }
        let previousEndpoint = preferences.endpoint
        guard preferences.save(endpoint: endpoint, token: token, deviceName: deviceName) else {
            errorMessage = preferences.errorMessage
            return
        }
        connectionRevision += 1
        continuationAnchors.removeAll()
        // Other servers' pending receipts stay on disk until the user switches back.
        recoveryTask?.cancel()
        spoolRetries.removeAll()
        if previousEndpoint != preferences.endpoint { undeliveredResults.removeAll() }
        serverHealth = nil
        sharedPreferences = nil
        generations = []
        historyCursor = nil
        hasMoreHistory = false
        serverStatusMessage = "Connecting…"
        refreshSavedRecordingCount()
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
        guard ["all", "inlay", "wispr-flow"].contains(source), source != historySourceFilter else { return }
        historySourceFilter = source
        generations = []
        historyCursor = nil
        hasMoreHistory = false
        refreshHistory()
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

    private func enrollThisDevice() async -> Bool {
        guard let connection = try? client() else { return false }
        let endpoint = preferences.endpoint
        do {
            let response = try await connection.enroll(
                device: DeviceIdentity(id: preferences.deviceID, name: preferences.deviceName))
            // A connection change mid-enroll must not store the old server's token under the new one.
            guard endpoint == preferences.endpoint else { return false }
            return preferences.replaceToken(response.token)
        } catch { return false }
    }

    func refreshDevices() async {
        guard let connection = try? client(), let list = try? await connection.devices() else { return }
        devices = list.devices
        legacyEnrollmentClosed = list.legacyEnrollmentClosed
    }

    func revokeDevice(_ id: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client().revokeDevice(id)
                await refreshDevices()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func closeLegacyEnrollment() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let list = try await client().closeLegacyEnrollment()
                devices = list.devices
                legacyEnrollmentClosed = list.legacyEnrollmentClosed
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func transcribeAgain(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client().reprocess(id)
                refreshServer()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func refreshStorageUsage() async {
        guard let connection = try? client(), let usage = try? await connection.storageUsage() else { return }
        storageUsage = usage
    }

    func purgeAudio(kind: AudioKind?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client().purgeAudio(PurgeAudioRequest(kind: kind))
                // Purges leave summaries unchanged, so the open detail reloads here.
                if let id = generationDetail?.id { loadGenerationDetail(id) }
                await refreshStorageUsage()
                refreshHistory()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func deleteGenerationAudio(_ id: UUID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client().deleteAudio(id)
                if generationDetail?.id == id { generationDetail = nil; loadGenerationDetail(id) }
                refreshHistory()
                await refreshStorageUsage()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    /// Connects this Mac to the app-managed local server after install:
    /// saves the endpoint + admin token, then the normal health flow
    /// auto-enrolls this Mac (stack 05) on the next refresh.
    @discardableResult
    func completeLocalSetup() -> Bool {
        guard !isBusy, let token = localServer.adminToken() else { return false }
        saveConnection(endpoint: ClientPreferencesStore.defaultEndpoint,
                       token: token, deviceName: preferences.deviceName)
        guard preferences.token == token else { return false }
        refreshServer()
        return true
    }

    func uninstallLocalServer() {
        localServer.uninstall()
        refreshServer()
    }

    /// Loads the full record for the history detail pane (summaries stay in the list).
    /// Reloading the shown record keeps it on screen until the fresh copy arrives.
    func loadGenerationDetail(_ id: UUID?) {
        detailTask?.cancel()
        if generationDetail?.id != id { generationDetail = nil }
        generationDetailFailedID = nil
        guard let id else { return }
        detailTask = Task { [weak self] in
            guard let self else { return }
            do {
                let record = try await client().generation(id)
                guard !Task.isCancelled else { return }
                generationDetail = record
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                generationDetailFailedID = id
            }
        }
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
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotFindHost, .dnsLookupFailed:
                return "Server not found at this address"
            case .timedOut:
                return "Server connection timed out"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected:
                return "Secure connection to the server failed"
            default:
                return "Server offline"
            }
        }
        return error.localizedDescription
    }

    func toggleTestRecording() {
        guard !hotkey.isHoldingFn else { return }
        if isCapturing { finishDictation() }
        else { beginDictation(isTest: true) }
    }

    func toggleMenuDictation() {
        guard !hotkey.isHoldingFn else { return }
        if isCapturing { finishDictation() }
        else { beginDictation(isTest: false) }
    }

    func cancelDictation() {
        guard isBusy else { return }
        var discardError: String?
        if isCapturing {
            let generation = activeGenerationID
            let connection = activeClient
            let spool = activeSpool
            resetSession()
            discardError = discardRecording(spool)
            if let generation, let connection { Task { try? await connection.cancel(generation) } }
        } else if activity.isBusy, let index = pendingDictations.lastIndex(where: { $0.session == sessionID }) {
            let pending = pendingDictations.remove(at: index)
            pending.cancel()
            if let id = pending.id {
                if let endpoint = pending.spool.manifest.endpoint, !removePendingEntry(id, endpoint: endpoint) {
                    discardError = "Could not save the cancellation. This result may reappear after relaunch."
                }
                Task { try? await pending.client.cancel(id) }
            }
            discardError = discardRecording(pending.spool) ?? discardError
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
        if remaining == nil { hudProgressText = nil }
        statusMessage = remaining == nil ? "Cancelled" : "Cancelled · Earlier dictation is still processing"
        errorMessage = nil
        onHUDVisibility?(remaining != nil)
        if let discardError {
            if remaining == nil { showError(discardError) }
            else { errorMessage = discardError; announceOutcome(discardError, .failure) }
        }
        refreshServer()
    }

    private func discardRecording(_ spool: RecordingSpool?) -> String? {
        guard let spool else { return nil }
        do { try spool.discard(); return nil }
        catch {
            failedDiscards.insert(spool.id)
            return "Could not confirm the discard. Before reopening Inlay, check the recording at \(spool.directory.path)."
        }
    }

    private func showEarlierDictation(_ pending: PendingDictation) {
        hudTask?.cancel()
        sessionID = pending.session
        activity = .transcribing
        statusMessage = "Earlier dictation is still processing"
        onHUDVisibility?(true)
    }

    /// Stops local activity; the caller decides whether to retain the spool.
    private func resetSession() {
        sessionID = UUID()
        hotkey.clearLatchedTake()
        microphoneStartTask?.cancel(); microphoneStartTask = nil
        activeSpool = nil
        uploadTask?.cancel(); uploadTask = nil
        destinationTask?.cancel(); destinationTask = nil
        stopRecordingTimer()
        recorder.cancel()
        outputMuter.restore()
        insertionDestination = nil
        recordingListHint = nil
        recordingInputName = nil
        activeGenerationID = nil
        activeClient = nil
        recordingFeedback.reset()
    }

    private func failSession(_ message: String, cancelServer: Bool) {
        let generation = activeGenerationID
        let connection = activeClient
        // Only the writer can declare its drain complete; a zero-byte snapshot
        // during teardown doesn't prove there is no admitted audio to save.
        resetSession()
        refreshSavedRecordingCount()
        showError(message)
        if cancelServer, let generation, let connection { Task { try? await connection.cancel(generation) } }
        refreshHistory()
    }

    private func addPendingEntry(id: UUID, endpoint: String, finish: FinishGenerationRequest, isTest: Bool) throws {
        guard !pendingEntries.contains(where: { $0.id == id && $0.endpoint == endpoint }) else { return }
        let next = pendingEntries + [PendingGenerationEntry(
            id: id, endpoint: endpoint, inferenceFrames: finish.inferenceFrames, originalFrames: finish.originalFrames,
            continuationID: finish.continuationID, isTest: isTest, sealedAt: Date())]
        guard pendingStore.save(next) else { throw CocoaError(.fileWriteUnknown) }
        pendingEntries = next
    }

    private var deviceIdentity: DeviceIdentity { .init(id: preferences.deviceID, name: preferences.deviceName) }

    /// Uploads a finished spool, start to end, to a new generation. The create
    /// request ID is persisted first, so a retry replays rather than duplicates.
    private static func uploadFresh(_ spool: RecordingSpool, connection: ServerClient, device: DeviceIdentity,
                                    mode: GenerationMode) async throws -> (id: UUID, outcome: UploadOutcome) {
        var created: GenerationRecord?
        for _ in 0..<2 {
            let requestID = spool.manifest.uploadRequestID ?? UUID()
            try Task.checkCancellation()
            if spool.manifest.uploadRequestID == nil { try spool.update { $0.uploadRequestID = requestID } }
            let record = try await connection.create(.init(requestID: requestID, device: device, mode: mode))
            if record.status == .receiving { created = record; break }
            // An earlier attempt with this ID already ended; start another.
            try spool.update { $0.uploadRequestID = nil }
        }
        guard let created else { throw ServerClientError.invalidResponse }
        let outcome = try await connection.upload(spool, to: created.id,
                                                  preserveOriginal: created.settings.preferences.keepOriginalAudio)
        guard outcome.complete else {
            if !outcome.canResume {
                try spool.update { $0.uploadRequestID = nil }
                Task { try? await connection.cancel(created.id) }
            }
            throw ServerClientError.disconnected
        }
        return (created.id, outcome)
    }

    /// Only released, unowned spools with a known matching endpoint may be recovered.
    private func savedRecordings(for endpoint: String) -> [RecordingSpool] {
        let owned = failedDiscards.union(pendingDictations.map(\.spool.id) + [activeSpool?.id].compactMap { $0 })
        return RecordingSpool.saved(in: clientRoot).filter { !owned.contains($0.id) && $0.manifest.endpoint == endpoint }
            .sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    private func refreshSavedRecordingCount() {
        let saved = savedRecordings(for: preferences.endpoint).filter { !$0.manifest.isTest && $0.snapshot().inferenceBytes >= 16_000 }
        savedRecordingCount = saved.count
        savedRecordingsNeedServerUpdate = serverHealth.map { health in
            saved.contains { $0.snapshot().inferenceBytes / 4 > Int64(16_000 * health.supportedRecordingSeconds) }
        } ?? false
    }

    private func recoverSavedRecordings(_ connection: ServerClient, endpoint: String, limit: Int) async {
        defer { if !isShuttingDown { refreshSavedRecordingCount() } }
        let device = deviceIdentity
        for spool in savedRecordings(for: endpoint) {
            guard !isShuttingDown, !Task.isCancelled, preferences.endpoint == endpoint else { return }
            if spool.manifest.isTest { spool.delete(); continue }
            // Never truncate or repeatedly upload a long local take to a legacy server.
            if spool.snapshot().inferenceBytes / 4 > Int64(limit * 16_000) { continue }
            if let retry = spoolRetries[spool.id], retry.nextAttempt > Date() { continue }
            do {
                try await recover(spool, connection, device: device, endpoint: endpoint)
                spool.delete()
                spoolRetries[spool.id] = nil
            } catch {
                if Task.isCancelled { return }
                let failures = min(7, (spoolRetries[spool.id]?.failures ?? 0) + 1)
                let delay = min(1_800, 30 * pow(2, Double(failures - 1)))
                spoolRetries[spool.id] = (failures, Date().addingTimeInterval(delay))
            }
        }
    }

    /// Returns only once both the server's seal and our local delivery marker are durable,
    /// or when the spool never reached the minimum capture duration.
    private func recover(_ spool: RecordingSpool, _ connection: ServerClient, device: DeviceIdentity,
                         endpoint: String) async throws {
        let manifest = spool.manifest
        if let sealed = manifest.sealingGenerationID, let frames = manifest.sealedInferenceFrames {
            let finish = FinishGenerationRequest(inferenceFrames: frames, originalFrames: manifest.sealedOriginalFrames,
                                                 continuationID: manifest.continuationID)
            var priorRequestID: UUID?
            var incompleteUpload = false
            do {
                var record = try await connection.generation(sealed)
                priorRequestID = record.requestID
                if record.status == .receiving {
                    do { record = try await connection.finish(sealed, value: finish) }
                    catch ServerClientError.rejected(409, _, "conflicting_finish") {
                        // Another finish won the race. Inspect its result rather than cancelling it.
                        record = try await connection.generation(sealed)
                    }
                }
                // Retention can remove artifacts after completion, but an archived
                // frame count that contradicts our seal is never proof of this take.
                let completed = record.status == .completed
                let speechMatches = record.inferenceAudio.map { $0.frameCount == frames } ?? completed
                let originalMatches = record.originalAudio.map { $0.frameCount == finish.originalFrames } ?? (completed || finish.originalFrames == nil)
                if record.status != .receiving && speechMatches && originalMatches {
                    try addPendingEntry(id: sealed, endpoint: endpoint, finish: finish, isTest: false)
                    return
                }
                guard record.status.isTerminal else { throw ServerClientError.invalidResponse }
            } catch let ServerClientError.rejected(status, _, code)
                        where status == 404 || (status == 409 && ["incomplete_audio", "incomplete_original"].contains(code)) {
                incompleteUpload = status == 409
            }
            // Retire this seal before creating again. A newer, separately keyed
            // partial upload still belongs to this spool and remains resumable.
            try spool.update {
                if $0.uploadRequestID == priorRequestID { $0.uploadRequestID = nil }
                $0.sealingGenerationID = nil; $0.sealedInferenceFrames = nil
                $0.sealedOriginalFrames = nil; $0.continuationID = nil
            }
            removePendingEntry(sealed, endpoint: endpoint)
            if incompleteUpload { Task { try? await connection.cancel(sealed) } }
        }
        let frames = spool.snapshot().inferenceBytes / 4
        guard frames >= 4_000 else { return }
        try Task.checkCancellation()
        let fresh = try await Self.uploadFresh(spool, connection: connection, device: device, mode: .dictation)
        let finish = fresh.outcome.finish
        guard finish.inferenceFrames == frames else { throw ServerClientError.invalidResponse }
        try spool.recordSeal(id: fresh.id, finish: finish)
        try addPendingEntry(id: fresh.id, endpoint: endpoint, finish: finish, isTest: false)
        _ = try await connection.finish(fresh.id, value: finish)
    }

    @discardableResult
    private func removePendingEntry(_ id: UUID, endpoint: String) -> Bool {
        let remaining = pendingEntries.filter { $0.id != id || $0.endpoint != endpoint }
        guard remaining.count != pendingEntries.count else { return true }
        pendingEntries = remaining
        if endpoint == preferences.endpoint { undeliveredResults.removeAll { $0.id == id } }
        return pendingStore.save(pendingEntries)
    }

    /// Surfaces takes that finished on the server while this app was not
    /// tracking them. Completed results are copy-only here: never inserted.
    private func reconcilePendingGenerations(_ connection: ServerClient, endpoint: String, revision: Int) async {
        // The health check owns this client. A settings change (even A → B → A)
        // invalidates its reads and retries; another check will pick up the receipts.
        func isCurrentConnection() -> Bool {
            revision == connectionRevision && endpoint == preferences.endpoint && !isShuttingDown && !Task.isCancelled
        }
        func isUnowned(_ entry: PendingGenerationEntry) -> Bool {
            pendingEntries.contains(entry) && !pendingDictations.contains { $0.id == entry.id }
        }
        func removeIfStillPending(_ entry: PendingGenerationEntry) {
            if isCurrentConnection(), isUnowned(entry) { removePendingEntry(entry.id, endpoint: endpoint) }
        }
        for entry in pendingEntries where entry.endpoint == endpoint {
            guard isCurrentConnection() else { return }
            guard isUnowned(entry) else { continue }
            let record: GenerationRecord
            do { record = try await connection.generation(entry.id) }
            catch ServerClientError.rejected(404, _, _) { removeIfStillPending(entry); continue }
            catch { continue }
            guard isCurrentConnection() else { return }
            guard isUnowned(entry) else { continue }
            switch record.status {
            case .completed:
                if record.delivery == nil, !record.finalText.isEmpty {
                    if !undeliveredResults.contains(where: { $0.id == record.id }) {
                        undeliveredResults.append(record)
                    }
                } else { removePendingEntry(entry.id, endpoint: endpoint) }
            case .failed, .cancelled:
                removePendingEntry(entry.id, endpoint: endpoint)
            case .receiving:
                do {
                    let finish = FinishGenerationRequest(inferenceFrames: entry.inferenceFrames, originalFrames: entry.originalFrames,
                                                         continuationID: entry.continuationID)
                    do { _ = try await connection.finish(entry.id, value: finish) }
                    catch let error as ServerClientError {
                        // A lost upload acknowledgement may leave the server one chunk ahead.
                        guard case .rejected(409, _, "incomplete_audio") = error,
                              let frames = entry.fallbackInferenceFrames else { throw error }
                        guard isCurrentConnection() else { return }
                        guard isUnowned(entry) else { continue }
                        _ = try await connection.finish(entry.id, value: .init(inferenceFrames: frames, originalFrames: nil))
                    }
                } catch let ServerClientError.rejected(status, _, _) where (400..<500).contains(status) && ![401, 403, 408, 429].contains(status) {
                    // Auth failures may come from a credential the user has just
                    // replaced; they do not prove the speech is unrecoverable.
                    removeIfStillPending(entry)
                } catch {}
            case .queued, .transcribing, .proofreading:
                break
            }
        }
    }

    func copyUndeliveredResult(_ record: GenerationRecord) {
        switch DictationClipboard.copy(record.finalText, to: .general) {
        case .success:
            lastRecordingSavedLocally = false
            lastTranscript = record.finalText
            lastAudioSeconds = record.audioSeconds > 0 ? record.audioSeconds : nil
            lastTranscriptionSeconds = (record.speech?.processingSeconds ?? 0) + (record.proofreading?.processingSeconds ?? 0)
            lastDelivery = "Copied to clipboard"
            lastDeliveryStatus = .copied
            removePendingEntry(record.id, endpoint: preferences.endpoint)
            let connection = try? client()
            Task {
                try? await connection?.delivery(record.id, receipt: DeliveryReceipt(
                    status: "copied", message: "Copied after relaunch"))
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty, !isBusy else { return }
        switch DictationClipboard.copy(lastTranscript, to: .general) {
        case .success:
            lastRecordingSavedLocally = false
            lastDelivery = "Copied to clipboard"; lastDeliveryStatus = .copied
        case .failure(let error): lastDelivery = error.localizedDescription; lastDeliveryStatus = .failed
        }
    }

    func clearLastTranscript() {
        guard !isBusy else { return }
        continuationAnchors.removeAll()
        lastRecordingSavedLocally = false
        lastTranscript = ""; lastTranscriptionSeconds = nil; lastAudioSeconds = nil
        lastDelivery = ""; lastDeliveryStatus = .none; errorMessage = nil; activity = .idle; attentionPresented = false
        recordingFeedback.reset()
    }

    func dismissFeedback() {
        guard !activity.isBusy else { return }
        hudTask?.cancel()
        attentionPresented = false
        recordingFeedback.reset()
        onHUDVisibility?(false)
        if activity == .success || activity == .failed {
            activity = .idle
            statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage
        }
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        wisprImport.shutdown()
        stopShortcutCheck()
        // Quitting stops an incomplete recording; its spool stays on disk and
        // is uploaded on the next launch. A sealed server generation remains
        // independently owned and may complete in history.
        let generation = activeGenerationID
        let connection = activeClient
        // Stop through the writer's normal drain (queued buffers, converter
        // flush, fsync) rather than cancelling, and let quit wait for it.
        let stopping = isCapturing ? recorder.stopCapture() : nil
        let earlier = recorderStopTask
        terminationDrain = Task {
            _ = try? await earlier?.value
            _ = try? await stopping?.value
        }
        resetSession()
        if let generation, let connection { Task { try? await connection.cancel(generation) } }
        stopPendingDictations()
        recoveryTask?.cancel(); monitorTask?.cancel(); refreshTask?.cancel(); hudTask?.cancel(); permissionTask?.cancel()
        configuration.stopWatching()
        subscriptions.removeAll()
        audioDevices.stop(); hotkey.stop(); continuationAnchors.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        try? FileManager.default.removeItem(at: InlayTemporaryDirectory.url.appendingPathComponent("Inlay-remote-preview"))
    }

    private func bindServices() {
        audioDevices.onChange = { [weak self] devices, defaultUID in self?.microphones.update(devices: devices, systemDefaultUID: defaultUID) }
        recorder.onLevel = { [weak self] level in guard let self, isCapturing else { return }; recordingFeedback.append(level) }
        recorder.onInterruption = { [weak self] message in self?.salvageDictation(reason: message) }
        hotkey.onStatusChange = { [weak self] in self?.isHotkeyActive = $0 }
        hotkey.onPress = { [weak self] in
            guard let self else { return false }
            if isCheckingShortcut {
                appendShortcutCheck("Shortcut recognized. Recording was intentionally skipped.")
                // No take started, so a double-tap monitor must not latch.
                return false
            }
            return beginDictation(isTest: false)
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            if isCheckingShortcut { appendShortcutCheck("Hold released."); return }
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
        permissions = PermissionSnapshot.capture()
        stopShortcutCheck()
        // A rejected press isn't a new take. Report why it can't start without
        // replacing a saved result or an earlier job that still owns the HUD.
        func reject(_ message: String) -> Bool {
            if lastRecordingSavedLocally || isBusy {
                errorMessage = message
                announceOutcome(message, .failure)
            } else { showError(message) }
            return false
        }
        guard isTest ? isServerReady : canStartDictation else { refreshServer(); return reject(serverStatusMessage) }
        guard permissions.microphone else { return reject("Allow microphone access, then try again.") }
        guard let input = microphones.resolution.device, let deviceID = audioDevices.deviceID(for: input.uid) else {
            return reject("No microphone is available. Connect an input and try again.")
        }
        guard isTest || Self.insertionMode(for: permissions) != .unavailable else {
            return reject("Allow Accessibility or Input Monitoring access, then try again.")
        }
        hudTask?.cancel(); errorMessage = nil; attentionPresented = false
        // Confirmed cursor moves matter only to takes that overlap them.
        if pendingDictations.isEmpty { insertionRebases.removeAll() }
        sessionID = UUID()
        let current = sessionID
        let live = isServerReady
        recordingLimit = live ? (serverHealth?.supportedRecordingSeconds ?? InlayAPI.maximumRecordingSeconds) : InlayAPI.maximumRecordingSeconds
        lastRecordingSavedLocally = false
        isTestSession = isTest
        sessionClipboardOnly = !isTest && Self.insertionMode(for: permissions) == .clipboardOnly
        recordingClipboardChangeCount = NSPasteboard.general.changeCount
        insertionDestination = nil
        recordingInputName = input.name
        recordingFeedback.reset()
        activity = .starting
        statusMessage = live ? "Connecting recording…" : "Starting local recording…"
        onHUDVisibility?(true)
        if muteOutputWhileRecording { outputMuter.mute() }
        if live, !isTest, !sessionClipboardOnly {
            let capture = TextInserter.beginDestinationCapture()
            destinationTask = capture
            Task { [weak self] in
                let destination = await capture.value
                guard let self, sessionID == current, isCapturing else { return }
                insertionDestination = destination
                prepareContinuation(for: destination.target.map(DictationDestination.field))
            }
        } else { prepareContinuation(for: .test) }
        microphoneStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == current { microphoneStartTask = nil } }
            do {
                let connection = try client()
                let endpoint = preferences.endpoint
                var created: GenerationRecord?
                if live {
                    do { created = try await connection.create(.init(requestID: current, device: deviceIdentity, mode: isTest ? .test : .dictation)) }
                    catch {
                        // Health can still be green when Wi-Fi drops between pressing the key and admission.
                        guard !isTest, !Task.isCancelled, Self.permitsLocalFallback(error) else { throw error }
                    }
                }
                guard sessionID == current, activity == .starting, !Task.isCancelled else {
                    if let created { Task { try? await connection.cancel(created.id) } }; return
                }
                if let created {
                    guard created.status == .receiving else { throw ServerClientError.invalidResponse }
                    activeGenerationID = created.id
                    sharedPreferences = created.settings
                } else {
                    destinationTask?.cancel(); destinationTask = nil
                    insertionDestination = .clipboard
                }
                activeClient = connection
                let spool = try RecordingSpool.create(in: clientRoot, id: current, endpoint: endpoint, isTest: isTest,
                                                      maximumSeconds: recordingLimit)
                activeSpool = spool
                let keepOriginal = created?.settings.preferences.keepOriginalAudio == true
                if let created {
                    uploadTask = Task { try await connection.upload(spool, to: created.id, preserveOriginal: keepOriginal) }
                }
                // A released take owns its teardown. Never let its asynchronous
                // stop consume the new microphone request.
                if let recorderStopTask { _ = try? await recorderStopTask.value }
                guard sessionID == current, activity == .starting, !Task.isCancelled else { return }
                recordingStart = ProcessInfo.processInfo.systemUptime
                statusMessage = "Starting microphone…"
                try await recorder.start(deviceID: deviceID, preserveOriginalAudio: keepOriginal, spool: spool)
                guard sessionID == current, activity == .starting, !Task.isCancelled else { return }
                activity = .recording
                statusMessage = created == nil ? "Recording on this Mac" : "Listening"
                announceOutcome(statusMessage, .start)
                startRecordingTimer()
            } catch is CancellationError {
            } catch AudioRecordingError.cancelled {
            } catch {
                guard sessionID == current, !Task.isCancelled else { return }
                if activeClient == nil { serverHealth = nil; serverStatusMessage = Self.connectionMessage(error) }
                failSession(Self.connectionMessage(error), cancelServer: true)
                refreshServer()
            }
        }
        return true
    }

    private static func permitsLocalFallback(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(urlError.code)
        }
        if case let ServerClientError.rejected(status, _, _) = error { return [408, 429, 502, 503, 504, 507].contains(status) }
        return false
    }

    /// Interruption path: drain the spool and
    /// deliver to the clipboard only. The captured insertion target cannot be
    /// trusted after sleep, lock, or device loss, so this never auto-inserts.
    private func salvageDictation(reason: String) {
        guard isCapturing else { return }
        guard activity == .recording else { cancelDictation(); return }
        finishDictation(interruption: reason)
    }

    private func finishDictation(atLimit: Bool = false, interruption: String? = nil) {
        guard isCapturing else { return }
        // A take ended by the duration limit must not leave a double-tap
        // latch behind, matching the failure and cancel paths.
        hotkey.clearLatchedTake()
        recorder.stopAcceptingAudio()
        outputMuter.restore()
        guard activity == .recording else { cancelDictation(); return }
        let releasedAt = ProcessInfo.processInfo.systemUptime
        destinationTask?.finish()
        guard releasedAt - recordingStart >= 0.25 else { cancelDictation(); showError("Too short — hold the key, speak, then release."); return }
        guard let connection = activeClient, let spool = activeSpool, let endpoint = spool.manifest.endpoint else {
            failSession("The recording could not be saved on this Mac.", cancelServer: true); return
        }
        stopRecordingTimer(); resetLevels()
        recordingFeedback.finish(atLimit: atLimit, limit: recordingLimit)
        activity = .transcribing
        statusMessage = interruption != nil ? "Saving interrupted recording…" : activeGenerationID == nil ? "Saving on this Mac…" : "Finishing upload…"
        if let interruption { errorMessage = interruption; announceOutcome("Recording interrupted. \(interruption)", .attention) }
        hudProgressText = activeGenerationID == nil ? "Saving" : "Uploading"
        let current = sessionID
        let test = isTestSession
        let capturedDestination = insertionDestination
        let clipboardCount = recordingClipboardChangeCount
        let pending = PendingDictation(session: current, id: activeGenerationID, client: connection, upload: uploadTask,
                                       spool: spool, destination: destinationTask)
        // Usually known at release, so a later take can continue a list in another field.
        let knownDestination: InsertionDestination? = test || interruption != nil || sessionClipboardOnly ? .clipboard : capturedDestination
        pending.target = knownDestination.map { Self.resolve($0, isTest: test, releasedAt: releasedAt) }
        pendingDictations.append(pending)
        activeGenerationID = nil; activeClient = nil; self.uploadTask = nil; activeSpool = nil
        destinationTask = nil; insertionDestination = nil; recordingListHint = nil; recordingInputName = nil
        let stopped = recorder.stopCapture()
        recorderStopTask = stopped
        let precedingDelivery = deliveryTail
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if pending.resolved, let id = pending.id { removePendingEntry(id, endpoint: endpoint) }
                pendingDictations.removeAll { $0 === pending }
                if !isShuttingDown { refreshSavedRecordingCount() }
                if pendingDictations.isEmpty {
                    deliveryTail = nil
                    applyConfiguration(configuration.configuration)
                }
            }
            do {
                // A salvaged take lives in the spool even if its local capture
                // died; the spool, not the stop result, is the recording.
                do { _ = try await stopped.value }
                catch { if interruption == nil { throw error } }
                pending.spool.finish()
                try Task.checkCancellation()
                guard let upload = pending.upload, let liveID = pending.id else {
                    guard pending.spool.snapshot().inferenceBytes >= 16_000 else { throw AudioRecordingError.noAudio }
                    if sessionID == current { showLocalSave(interruption: interruption) }
                    return // Recovery on a healthy check is always manual-copy, never insertion.
                }
                var uploadOutcome = try await upload.value
                if !uploadOutcome.complete {
                    // The server stopped taking this generation's audio (an
                    // outage, restart, or idle expiry). Send the whole spool to
                    // a fresh generation instead of keeping only a prefix.
                    if uploadOutcome.canResume { throw ServerClientError.disconnected }
                    Task { try? await connection.cancel(liveID) }
                    if sessionID == current { statusMessage = "Re-uploading recording…"; hudProgressText = "Uploading" }
                    let fresh = try await Self.uploadFresh(pending.spool, connection: connection, device: deviceIdentity,
                                                           mode: test ? .test : .dictation)
                    pending.id = fresh.id
                    uploadOutcome = fresh.outcome
                }
                let id = pending.id ?? liveID
                var finish = uploadOutcome.finish
                if finish.inferenceFrames < 4_000 {
                    pending.spool.delete()
                    throw ServerClientError.rejected(422, "The recording was too short to save.", "")
                }
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
                // Record the seal before sending it; without that record a lost
                // response could later re-upload a take the server already has.
                try pending.spool.recordSeal(id: id, finish: finish)
                try addPendingEntry(id: id, endpoint: endpoint, finish: finish, isTest: test)
                pending.sealed = true // A lost response is not a rejected seal.
                var result: GenerationRecord
                do { result = try await connection.finish(id, value: finish) }
                catch let ServerClientError.rejected(status, message, code) where (400..<500).contains(status) && ![408, 429].contains(status) {
                    pending.sealed = false // The server answered without sealing, so cancel promptly.
                    throw ServerClientError.rejected(status, message, code)
                }
                // The server now holds the complete take durably.
                pending.spool.delete()
                try Task.checkCancellation()
                if !result.status.isTerminal {
                    result = try await connection.events(id) { [weak self] record in
                        await self?.applyProgress(record, session: current)
                    }
                }
                try Task.checkCancellation()
                guard result.status == .completed else {
                    pending.resolved = true // Terminal on the server; visible in History.
                    throw ServerClientError.rejected(422, result.error ?? "The server could not process this recording.", "")
                }
                // Processing and uploads overlap. Clipboard/paste transactions
                // remain ordered and each keeps its original destination.
                await precedingDelivery?.value
                await waitForCaptureRelease()
                try Task.checkCancellation()
                let deliveryDestination = rebasedDestination(resolved)
                var receipt = await deliver(result, to: deliveryDestination, anchor: anchor, isTest: test,
                                            clipboardCount: clipboardCount, session: current)
                try Task.checkCancellation()
                if interruption != nil {
                    let message = "Recording was interrupted. \(receipt.message ?? "")".trimmingCharacters(in: .whitespaces)
                    receipt.message = message
                    if sessionID == current { lastDelivery = message; errorMessage = nil }
                }
                do { try await connection.delivery(id, receipt: receipt) }
                catch { continuationAnchors.removeAll { $0.generationID == id } }
                try Task.checkCancellation()
                // Other takes can change the shared last-delivery state during the receipt request.
                let delivered = DictationDeliveryStatus(rawValue: receipt.status) ?? .failed
                if sessionID == current {
                    hudProgressText = nil
                    activity = delivered == .failed ? .failed : .success
                    if delivered.needsAttention {
                        attentionPresented = true
                        if delivered == .copied { dismissHUDAfter(seconds: 2, clearAttention: true) }
                    } else { dismissHUDAfter(seconds: 1.7) }
                    let outcomeSound: OutcomeFeedback.Sound =
                        switch delivered {
                        case .inserted, .tested, .listUpdated: .success
                        case .copied, .unconfirmed: .attention
                        case .failed, .none: .failure
                        }
                    announceOutcome(receipt.message ?? delivered.hudLabel, outcomeSound)
                } else if delivered.needsAttention {
                    let message = "Earlier dictation: \(receipt.message ?? delivered.hudLabel)"
                    if !lastRecordingSavedLocally { errorMessage = message }
                    announceOutcome(message, .attention)
                }
                pending.resolved = true
                refreshServer()
            } catch {
                pending.upload?.cancel(); pending.destination?.cancel()
                if !pending.sealed, let id = pending.id {
                    pending.resolved = true
                    Task { try? await connection.cancel(id) }
                }
                guard !Task.isCancelled else { return }
                // Unless the user discarded it, an unsealed take stays on disk
                // and is uploaded again once the server can take it.
                let saved = !test && FileManager.default.fileExists(atPath: pending.spool.directory.path)
                    && pending.spool.snapshot().inferenceBytes / 4 >= 4_000
                let failure = saved
                    ? "Recording saved on this Mac. Inlay will transcribe it when the server is reachable."
                    : Self.connectionMessage(error)
                if let clientError = error as? ServerClientError, case .processingTimedOut = clientError {
                    // Not a failure: stop blocking later deliveries and let the
                    // persisted-pending reconciliation surface the result.
                    if sessionID == current {
                        activity = .idle
                        statusMessage = "Still processing on the server"
                    }
                } else if sessionID == current {
                    if error is URLError { serverHealth = nil; serverStatusMessage = Self.connectionMessage(error) }
                    if saved { showLocalSave(interruption: interruption) } else { showError(failure) }
                } else {
                    let message = saved ? "Earlier dictation: \(failure)" : "Earlier dictation failed: \(failure)"
                    if !lastRecordingSavedLocally {
                        errorMessage = message
                        lastDelivery = message
                        lastDeliveryStatus = .failed
                    }
                    if !activity.isBusy, !lastRecordingSavedLocally { showError(message) }
                    else { announceOutcome(message, .failure) }
                }
                refreshHistory()
            }
        }
        pending.task = task
        // Even a failed/cancelled middle take must preserve the ordering link
        // to earlier deliveries for every later take.
        deliveryTail = Task {
            await precedingDelivery?.value
            await task.value
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
        case .queued:
            if let position = generation.queuePosition {
                statusMessage = "Queued on server… (#\(position))"
                hudProgressText = "Queued #\(position)"
            } else {
                statusMessage = "Queued on server…"; hudProgressText = "Queued"
            }
        case .transcribing: statusMessage = "Transcribing on server…"; hudProgressText = "Transcribing"
        case .proofreading: statusMessage = "Proofreading on server…"; hudProgressText = "Proofreading"
        case .completed: statusMessage = "Preparing result…"; hudProgressText = "Preparing"
        case .failed, .cancelled: statusMessage = generation.error ?? "Processing stopped"; hudProgressText = nil
        }
    }

    private func deliver(_ record: GenerationRecord, to destination: InsertionDestination,
                         anchor: DictationDestination?, isTest: Bool, clipboardCount: Int,
                         session: UUID) async -> DeliveryReceipt {
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
                                                  preservingClipboard: preserveClipboard)
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
        // An older server delivery still gets its receipt and History entry,
        // but cannot replace a newer take displayed as saved on this Mac.
        if sessionID == session || !lastRecordingSavedLocally {
            lastRecordingSavedLocally = false
            lastTranscript = transcript
            lastAudioSeconds = record.audioSeconds
            lastTranscriptionSeconds = (record.speech?.processingSeconds ?? 0) + (record.proofreading?.processingSeconds ?? 0)
            lastDelivery = message
            lastDeliveryStatus = deliveryStatus
            if sessionID == session { statusMessage = status }
        }
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
            if !pending.sealed, let id = pending.id {
                if let endpoint = pending.spool.manifest.endpoint { removePendingEntry(id, endpoint: endpoint) }
                Task { try? await pending.client.cancel(id) }
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

    private func showLocalSave(interruption: String? = nil) {
        lastRecordingSavedLocally = true
        statusMessage = "Saved on this Mac"
        lastDelivery = interruption.map { "Recording interrupted: \($0) The captured audio is saved on this Mac." }
            ?? "Inlay will transcribe this recording when its server is ready."
        errorMessage = nil; hudProgressText = nil
        activity = .success; attentionPresented = true
        announceOutcome(statusMessage, .attention)
        onHUDVisibility?(true)
        dismissHUDAfter(seconds: 3, clearAttention: true)
    }

    private func showError(_ message: String) {
        lastRecordingSavedLocally = false
        hudProgressText = nil
        recordingFeedback.reset()
        activity = .failed; errorMessage = message; statusMessage = message
        announceOutcome(message, .failure)
        onHUDVisibility?(true)
        dismissHUDAfter(seconds: 4)
    }

    private func dismissHUDAfter(seconds: Double, clearAttention: Bool = false) {
        hudTask?.cancel()
        hudTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !activity.isBusy else { return }
            if clearAttention { attentionPresented = false }
            // A newer take's result was shown; return the HUD to earlier work.
            if !lastRecordingSavedLocally, let earlier = pendingDictations.last { showEarlierDictation(earlier); return }
            onHUDVisibility?(false)
            recordingFeedback.reset()
            if (activity == .success || activity == .failed), !attentionPresented { activity = .idle; statusMessage = isServerReady ? "Ready when you are" : serverStatusMessage }
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
        // Salvage a live take (best effort before suspend) and leave sealed
        // pendings running: their recovery continues after wake.
        if isCapturing { salvageDictation(reason: "Recording interrupted while your Mac was away.") }
        continuationAnchors.removeAll()
    }
    func refreshPermissions() {
        let current = PermissionSnapshot.capture()
        if current != permissions { permissions = current }
        audioDevices.refresh()
        if permissions.canListenForHotkey {
            isHotkeyActive = hotkey.start()
        } else {
            hotkey.stop()
            isHotkeyActive = false
        }
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
        appendShortcutCheck("Checking \(shortcut.title) for 60 seconds. The microphone stays off.")
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

    private func appendShortcutCheck(_ message: String) {
        guard isCheckingShortcut else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - shortcutCheckStarted
        let context = NSApp.isActive ? "Inlay" : "background"
        shortcutCheckEntries.append(String(format: "%.2fs", elapsed) + " [\(context)] " + message)
        shortcutCheckEntries = Array(shortcutCheckEntries.suffix(16))
        shortcutCheckText = shortcutCheckEntries.joined(separator: "\n")
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCapturing else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - self.recordingStart
                self.recordingFeedback.updateElapsed(elapsed, limit: self.recordingLimit)
                if elapsed >= Double(self.recordingLimit) { self.finishDictation(atLimit: true) }
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
            loginItemError = "Allow Inlay in System Settings → General → Login Items to finish enabling this preference."
            return
        }
        // A rebuilt accessory app may report .notFound even though login is
        // already off. Do not attempt to unregister an absent service.
        if !launchAtLogin, status != .enabled, status != .requiresApproval { return }
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            if launchAtLogin, SMAppService.mainApp.status == .requiresApproval {
                loginItemError = "Allow Inlay in System Settings → General → Login Items to finish enabling this preference."
            }
        } catch {
            // Keep the desired setting consistent between UI and JSON. A denied
            // OS operation must not trigger file rollback/retry feedback loops.
            loginItemError = "Couldn’t update launch at login: \(error.localizedDescription)"
        }
    }


}
