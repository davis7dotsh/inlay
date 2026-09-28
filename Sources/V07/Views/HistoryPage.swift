import AppKit
import V07API
import SwiftUI

struct HistoryPage: View {
    @ObservedObject var controller: V07Controller
    @State private var selectedID: UUID?
    @State private var deviceID = "all"
    @State private var confirmingDelete = false
    @State private var copiedID: UUID?
    @State private var showingWisprFlowImport = false

    private var devices: [DeviceIdentity] {
        var seen = Set<String>()
        return controller.generations.map(\.device).filter { seen.insert($0.id).inserted }.sorted { $0.name < $1.name }
    }
    private var filtered: [GenerationRecord] {
        controller.generations.filter { deviceID == "all" || $0.device.id == deviceID }
    }
    private var selected: GenerationRecord? {
        filtered.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                V07PageHeading(title: "History")
                Picker("Device", selection: $deviceID) {
                    Text("All devices").tag("all")
                    ForEach(devices, id: \.id) { device in Text(device.name).tag(device.id) }
                }
                .labelsHidden()
                .frame(width: 180)
                Picker("Source", selection: Binding(get: { controller.historySourceFilter },
                                                     set: controller.setHistorySourceFilter)) {
                    Text("All sources").tag("all")
                    Text("V07").tag("v07")
                    Text("Wispr Flow").tag("wispr-flow")
                }
                .labelsHidden()
                .frame(width: 130)
                .accessibilityIdentifier("history.source-filter")
                Button {
                    controller.errorMessage = nil
                    controller.refreshHistory()
                } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh shared history")
                    .accessibilityLabel("Refresh shared history")
            }
            VStack(spacing: 4) {
                ServerConnectionStatus(controller: controller)
                V07ActionMessage(message: controller.errorMessage)
            }

            HSplitView {
                historyList.frame(minWidth: 220, idealWidth: 255, maxWidth: 320)
                detail.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            HStack {
                Text("\(filtered.count) sessions\(controller.hasMoreHistory ? " loaded" : "")")
                    .font(.caption)
                    .foregroundStyle(V07Palette.muted)
                Spacer()
                Button("Import Wispr Flow history") {
                    showingWisprFlowImport = true
                    controller.prepareWisprFlowImport()
                }
                .disabled(controller.isBusy)
                .accessibilityIdentifier("history.import-wispr-flow")
                if controller.isLoadingHistory { ProgressView().controlSize(.mini) }
                Button("Load older") {
                    controller.errorMessage = nil
                    controller.loadMoreHistory()
                }
                .opacity(controller.hasMoreHistory ? 1 : 0)
                .disabled(!controller.hasMoreHistory || controller.isLoadingHistory)
            }
            .frame(height: 28)
        }
        .padding(26)
        .onAppear { controller.refreshHistory() }
        .onChange(of: controller.historySourceFilter) { _, _ in
            deviceID = "all"
            selectedID = nil
        }
        .sheet(isPresented: $showingWisprFlowImport) {
            WisprFlowImportSheet(controller: controller)
                .onDisappear { controller.closeWisprFlowImportSheet() }
        }
        .confirmationDialog("Delete this dictation from the server?", isPresented: $confirmingDelete) {
            if let selected {
                Button("Delete dictation", role: .destructive) {
                    controller.errorMessage = nil
                    controller.deleteGeneration(selected.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its archived text and files will be removed from every device’s history.")
        }
    }

    private var historyList: some View {
        List(selection: $selectedID) {
            ForEach(filtered) { generation in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(generation.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                        Spacer(minLength: 4)
                        if generation.status != .completed {
                            Image(systemName: generation.status == .failed ? "exclamationmark.circle" : "clock")
                                .foregroundStyle(V07Palette.warning)
                        }
                    }
                    Text(summary(generation))
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    Label(sourceLabel(generation),
                          systemImage: generation.importedSource == nil ? "laptopcomputer" : "square.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(V07Palette.muted)
                        .lineLimit(1)
                }
                .padding(.vertical, 8)
                .tag(generation.id)
                .accessibilityLabel("\(sourceLabel(generation)), \(summary(generation))")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("No dictations", systemImage: "waveform",
                                       description: Text("Record while connected to add a dictation."))
            }
        }
        .accessibilityIdentifier("history.list")
    }

    @ViewBuilder private var detail: some View {
        if let selected {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(selected.createdAt, format: .dateTime.month(.wide).day().hour().minute()).font(.headline)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        if NSPasteboard.general.setString(selected.finalText, forType: .string) { copiedID = selected.id }
                    } label: { Image(systemName: copiedID == selected.id ? "checkmark" : "doc.on.doc") }
                        .disabled(selected.finalText.isEmpty)
                        .help("Copy transcript")
                        .accessibilityLabel("Copy transcript")
                    Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .disabled(!selected.status.isTerminal || controller.serverHealth == nil)
                        .help("Delete from server")
                        .accessibilityLabel("Delete dictation")
                }
                HStack(spacing: 12) {
                    Label(sourceLabel(selected),
                          systemImage: selected.importedSource == nil ? "laptopcomputer" : "square.and.arrow.down")
                    if selected.importedSource == nil { Text(statusLabel(selected.status)) }
                    if selected.delivery?.status == "cancelled" { Text("Not pasted") }
                    if let sourceStatus = selected.importedSource?.sourceStatus, !sourceStatus.isEmpty {
                        Text("Flow status: \(sourceStatus)")
                    }
                    if selected.audioSeconds > 0 { Text(v07Duration(selected.audioSeconds)).monospacedDigit() }
                }
                .font(.caption)
                .foregroundStyle(V07Palette.muted)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = selected.error {
                            Text(error).foregroundStyle(V07Palette.warning)
                        }
                        Text(selected.finalText.isEmpty ? "No transcript available." : selected.finalText)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !selected.rawText.isEmpty && selected.rawText != selected.finalText {
                            DisclosureGroup(selected.importedSource == nil ? "Original transcript" : "Wispr Flow ASR") {
                                Text(selected.rawText)
                                    .font(.callout)
                                    .foregroundStyle(V07Palette.muted)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                        }
                        if let source = selected.importedSource, !source.variantNames.isEmpty {
                            Text("Stored text versions: \(source.variantNames.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(V07Palette.muted)
                        }
                        if let reason = selected.formattingRejectionReason {
                            Text(reason).font(.caption).foregroundStyle(V07Palette.warning)
                        }
                        if let processing = selected.textProcessing {
                            if let reason = processing.reason {
                                Text(reason).font(.caption).foregroundStyle(V07Palette.warning)
                            }
                            if processing.status == .rejected, let proposed = processing.proposedText {
                                DisclosureGroup("Rejected cleanup") {
                                    Text(proposed).font(.callout).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if let hints = selected.recognitionHints, !hints.omittedTerms.isEmpty {
                            hintDetails("Voice vocabulary", hints: hints)
                        }
                        if let hints = selected.proofreadingHints, !hints.omittedTerms.isEmpty {
                            hintDetails("Cleanup vocabulary", hints: hints)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack {
                    if selected.canTranscribeAgain {
                        Button("Transcribe again") {
                            controller.errorMessage = nil
                            controller.retryGeneration(selected.id)
                        }
                        .disabled(controller.serverHealth == nil)
                        .help("Transcribe the saved audio again. Nothing is pasted.")
                    }
                    if selected.inferenceAudio != nil {
                        Button("Open audio") {
                            controller.errorMessage = nil
                            controller.openGenerationAudio(selected, kind: .inference)
                        }
                    }
                    if selected.originalAudio != nil {
                        Button("Open original") {
                            controller.errorMessage = nil
                            controller.openGenerationAudio(selected, kind: .original)
                        }
                    }
                    if let source = selected.importedSource {
                        if source.artifactNames.contains(.sourceWAV) {
                            Button("Open Wispr Flow audio") {
                                controller.openWisprFlowArtifact(selected, filename: .sourceWAV)
                            }
                        }
                        if !source.artifactNames.isEmpty {
                            Menu("Source files") {
                                ForEach(source.artifactNames, id: \.rawValue) { filename in
                                    Button(sourceFileLabel(filename)) {
                                        controller.openWisprFlowArtifact(selected, filename: filename)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .frame(height: 28)
                .disabled(controller.serverHealth == nil)
                if let speech = selected.speech {
                    Text("\(speech.modelID) · \(speech.backend)")
                        .font(.caption2)
                        .foregroundStyle(V07Palette.muted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("history.detail")
        } else {
            ContentUnavailableView("Select a dictation", systemImage: "text.alignleft")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusLabel(_ status: GenerationStatus) -> String {
        switch status {
        case .receiving: "Recording"
        case .queued: "Queued"
        case .transcribing: "Transcribing"
        case .proofreading: "Proofreading"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func sourceLabel(_ generation: GenerationRecord) -> String {
        generation.importedSource == nil ? generation.device.name : "Imported from Wispr Flow"
    }

    private func summary(_ generation: GenerationRecord) -> String {
        if !generation.finalText.isEmpty { return generation.finalText }
        return generation.importedSource == nil ? statusLabel(generation.status) : "No transcript recovered"
    }

    private func sourceFileLabel(_ filename: WisprFlowArtifactName) -> String {
        switch filename {
        case .sourceJSON: "Full source data"
        case .sourceWAV: "Wispr Flow audio"
        case .opusJSON: "Opus packets"
        case .screenshotPNG: "Screenshot"
        case .builtInAudio: "Built-in audio (unarchived)"
        }
    }

    private func hintDetails(_ title: String, hints: ModelHintUsage) -> some View {
        DisclosureGroup("\(title): \(hints.omittedTerms.count) terms did not fit") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Used: \(hints.includedTerms.isEmpty ? "None" : hints.includedTerms.joined(separator: ", "))")
                Text("Did not fit: \(hints.omittedTerms.joined(separator: ", "))")
            }
            .font(.caption)
            .foregroundStyle(V07Palette.muted)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WisprFlowImportSheet: View {
    @ObservedObject var controller: V07Controller
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Import Wispr Flow history")
                .font(.title2.weight(.semibold))

            Group {
                switch controller.wisprFlowImportState {
                case .idle, .preparing:
                    VStack(alignment: .leading, spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Reading local Wispr Flow history…")
                            .foregroundStyle(V07Palette.muted)
                    }
                case .preview(let preview, let knownCount, let destinationError):
                    previewContent(preview, knownCount: knownCount, destinationError: destinationError)
                case .running(let preview, let counts):
                    progressContent(preview, counts: counts)
                case .finished(let preview, let counts, let cancelled):
                    resultContent(preview, counts: counts, cancelled: cancelled)
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(V07Palette.warning)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                Text("Destination: \(controller.preferences.endpoint)")
                    .font(.caption)
                    .foregroundStyle(V07Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                actions
            }
        }
        .padding(24)
        .frame(width: 520, height: 380)
        .interactiveDismissDisabled(isImporting)
        .accessibilityIdentifier("wispr-flow-import.sheet")
    }

    private var isImporting: Bool {
        if case .running = controller.wisprFlowImportState { return true }
        return false
    }

    private func previewContent(_ preview: WisprFlowImportPreview, knownCount: Int?,
                                destinationError: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(preview.sessionCount) sessions found")
                    .font(.headline)
                if let earliest = preview.earliestDate, let latest = preview.latestDate {
                    Text("\(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
                        .foregroundStyle(V07Palette.muted)
                }
                Divider()
                countRow("With transcripts", count: preview.transcriptCount)
                countRow("Without text", count: preview.sessionCount - preview.transcriptCount)
                countRow("Metadata only", count: preview.metadataOnlyCount)
                countRow("WAV found", count: preview.wavCount)
                countRow("Opus packet sets", count: preview.opusCount)
                countRow("Screenshots", count: preview.screenshotCount)
                countRow("Dictionary entries to archive", count: preview.dictionaryCount)
                if let knownCount {
                    countRow("Already in V07", count: knownCount)
                }
                if let destinationError {
                    Text(destinationError).font(.caption).foregroundStyle(V07Palette.warning)
                }
                Text("About \(ByteCountFormatter.string(fromByteCount: preview.estimatedArtifactBytes, countStyle: .file)) of source files")
                    .font(.caption)
                    .foregroundStyle(V07Palette.muted)
                Text("Sources: \(sourceSummary(preview.sourceURLs))")
                    .font(.caption)
                    .foregroundStyle(V07Palette.muted)
                ForEach(preview.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(V07Palette.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressContent(_ preview: WisprFlowImportPreview, counts: WisprFlowImportCounts) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Importing \(preview.sessionCount) sessions")
                .font(.headline)
            ProgressView(value: Double(counts.processed), total: Double(max(1, counts.total)))
                .accessibilityIdentifier("wispr-flow-import.progress")
            Text("\(counts.processed) of \(counts.total) processed")
                .monospacedDigit()
                .foregroundStyle(V07Palette.muted)
            Text("\(counts.imported) imported · \(counts.enriched) enriched · \(counts.skipped) complete · \(counts.partial) partial · \(counts.failed) failed")
                .font(.caption)
        }
    }

    private func resultContent(_ preview: WisprFlowImportPreview, counts: WisprFlowImportCounts,
                               cancelled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cancelled ? "Import stopped" : (counts.processed < preview.sessionCount ? "Import incomplete" : "Import complete"))
                .font(.headline)
            Text("\(counts.processed) of \(preview.sessionCount) sessions processed")
                .monospacedDigit()
            countRow("Imported", count: counts.imported)
            countRow("Enriched", count: counts.enriched)
            countRow("Already complete", count: counts.skipped)
            countRow("Partial media", count: counts.partial)
            countRow("Failed", count: counts.failed)
            if preview.dictionaryCount > 0 {
                Text(counts.dictionaryArchived ? "Dictionary archived" : "Dictionary was not archived")
                    .font(.caption)
                    .foregroundStyle(counts.dictionaryArchived ? V07Palette.muted : V07Palette.warning)
            }
            if let warning = counts.warning {
                Text(warning).font(.caption).foregroundStyle(V07Palette.warning)
            }
            if let warning = counts.unarchivedWarning {
                Text(warning).font(.caption).foregroundStyle(V07Palette.warning)
            }
        }
    }

    private func countRow(_ label: String, count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.callout)
    }

    private func sourceSummary(_ urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent)
        var parts: [String] = []
        if names.contains("flow.sqlite") { parts.append("flow.sqlite") }
        let backups = names.filter { $0.hasPrefix("backup-") }.count
        if backups > 0 { parts.append("\(backups) backup\(backups == 1 ? "" : "s")") }
        let selected = names.count - (names.contains("flow.sqlite") ? 1 : 0) - backups
        if selected > 0 { parts.append("\(selected) selected file\(selected == 1 ? "" : "s")") }
        return parts.joined(separator: " + ")
    }

    @ViewBuilder private var actions: some View {
        switch controller.wisprFlowImportState {
        case .idle, .preparing:
            Button("Cancel") { controller.cancelWisprFlowImport(); dismiss() }
        case .preview(_, _, let destinationError):
            Button("Cancel") { dismiss() }
            Button("Import") { controller.startWisprFlowImport() }
                .buttonStyle(.borderedProminent)
                .disabled(destinationError != nil || controller.serverHealth?.apiVersion != V07API.version || controller.isBusy)
                .accessibilityIdentifier("wispr-flow-import.start")
        case .running:
            Button("Cancel import") { controller.cancelWisprFlowImport() }
        case .finished:
            Button("Done") { dismiss() }
        case .failed:
            Button("Close") { dismiss() }
            Button("Try again") { controller.prepareWisprFlowImport() }
        }
    }
}

private extension GenerationRecord {
    /// Sealed audio outlives a failed or cancelled run on the server.
    var canTranscribeAgain: Bool {
        importedSource == nil && inferenceAudio != nil && (status == .failed || status == .cancelled)
    }
}
