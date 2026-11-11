import Combine
import Foundation
import InlayAPI

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


/// Drives the one-way Wispr Flow migration import. Isolated from dictation so
/// the bridge can be deleted without touching the dictation path (Batch 8).
@MainActor
final class WisprFlowImportDriver: ObservableObject {
    @Published private(set) var state: WisprFlowImportState = .idle
    private var wisprFlowReader: WisprFlowSourceReader?
    private var wisprFlowPrepareTask: Task<Void, Never>?
    private var wisprFlowPrepareGate: WisprFlowPreparationGate?
    private var wisprFlowPrepareRevision = 0
    private var wisprFlowImportTask: Task<Void, Never>?
    private var wisprFlowMaterializationTask: Task<WisprFlowSourceSession, Error>?
    private var wisprFlowImportRevision = 0
    private var wisprFlowActiveReaders: [Int: WisprFlowSourceReader] = [:]
    private var wisprFlowDestinationEndpoint: String?

    private let makeClient: () throws -> ServerClient
    private let isDictationBusy: () -> Bool
    private let endpoint: () -> String
    private let onHistoryChanged: (Bool) -> Void

    init(makeClient: @escaping () throws -> ServerClient,
         isDictationBusy: @escaping () -> Bool,
         endpoint: @escaping () -> String,
         onHistoryChanged: @escaping (Bool) -> Void) {
        self.makeClient = makeClient
        self.isDictationBusy = isDictationBusy
        self.endpoint = endpoint
        self.onHistoryChanged = onHistoryChanged
    }

    var isImportRunning: Bool { wisprFlowImportTask != nil }

    func shutdown() {
        wisprFlowPrepareTask?.cancel()
        wisprFlowImportTask?.cancel()
        wisprFlowMaterializationTask?.cancel()
        wisprFlowPrepareGate?.cancel(waitForWorker: true)
        wisprFlowPrepareGate = nil
        for reader in wisprFlowActiveReaders.values { reader.close() }
        wisprFlowActiveReaders.removeAll()
        wisprFlowReader?.close()
        wisprFlowReader = nil
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
        state = .preparing
        wisprFlowDestinationEndpoint = endpoint()
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
                    knownCount = try await makeClient().knownWisprFlowSourceIDs(reader.sourceIDs).count
                    destinationError = nil
                } catch {
                    knownCount = nil
                    if let clientError = error as? ServerClientError,
                       case .rejected(let status, _, _) = clientError, status == 404 {
                        destinationError = "This server does not support Wispr Flow imports. Connect the new Inlay Dev server."
                    } else {
                        destinationError = "Cannot check the destination server: \(error.localizedDescription)"
                    }
                }
                try Task.checkCancellation()
                guard revision == wisprFlowPrepareRevision else { return }
                state = .preview(reader.preview, knownCount: knownCount,
                                               destinationError: destinationError)
            } catch is CancellationError {
            } catch {
                guard revision == wisprFlowPrepareRevision, !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func startWisprFlowImport() {
        guard case .preview(let preview, _, let destinationError) = state,
              destinationError == nil,
              let reader = wisprFlowReader,
              wisprFlowImportTask == nil, !isDictationBusy() else { return }
        guard wisprFlowDestinationEndpoint == endpoint() else {
            state = .failed("The server connection changed. Preview the import again.")
            return
        }
        let connection: ServerClient
        do { connection = try makeClient() }
        catch { state = .failed(error.localizedDescription); return }
        let counts = WisprFlowImportCounts(total: reader.sourceIDs.count)
        wisprFlowImportRevision += 1
        let revision = wisprFlowImportRevision
        // The import task owns this reader until its detached work and artifact
        // cleanup finish. A new preview may start immediately after cancellation.
        wisprFlowActiveReaders[revision] = reader
        wisprFlowReader = nil
        state = .running(preview, counts)
        wisprFlowImportTask = Task { [weak self] in
            await self?.runWisprFlowImport(reader: reader, preview: preview, connection: connection,
                                           counts: counts, revision: revision)
        }
    }

    func cancelWisprFlowImport() {
        if case .running(let preview, let counts) = state {
            // Awaiting an unstructured reader task does not wake when its parent
            // is cancelled. Release the sheet now; the old task retains and
            // cleans its reader when materialization actually stops.
            wisprFlowImportRevision += 1
            wisprFlowMaterializationTask?.cancel()
            wisprFlowMaterializationTask = nil
            wisprFlowImportTask?.cancel()
            wisprFlowImportTask = nil
            wisprFlowDestinationEndpoint = nil
            state = .finished(preview, counts, cancelled: true)
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
        state = .idle
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
                       case .rejected(let status, _, _) = clientError, [401, 403].contains(status) {
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
            if revision == wisprFlowImportRevision { state = .running(preview, counts) }
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
            onHistoryChanged(revision == wisprFlowImportRevision)
        }
        guard revision == wisprFlowImportRevision else { return }
        wisprFlowImportTask = nil
        wisprFlowDestinationEndpoint = nil
        state = .finished(preview, counts, cancelled: cancelled)
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

}
