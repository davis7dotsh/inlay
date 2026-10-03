# Import Wispr Flow history into Inlay

The current feature reads the local Wispr Flow database and its complete backups. It previews the recoverable rows, then imports only after an explicit click. The import archives source fields and media without running Inlay's models or changing Wispr Flow. Choosing an arbitrary SQLite file or ingesting an account export remains future work.

## Goal and source

Add **Import from Wispr Flow** to Inlay's History page. Read historical dictations from the local Wispr Flow `flow.sqlite` without changing the source database, then archive the recoverable text, media, and source fields on the Inlay server. This is an archive import: it must not run Inlay's speech or cleanup models, paste old text, or delete source data.

[WisprSync](https://github.com/fjooord/WisprSync) is a useful reference for database discovery, `History`/`Dictionary` field names, and media extraction. It exports local SQLite to files; it does not import into Inlay. Its current export omits several selected fields and `opusChunks`, so Inlay should read SQLite directly and preserve unmapped source values. A WisprSync archive or another SQLite file can be a later fallback source.

Wispr Flow documents that dictation history is local to each device and is not exposed by its MCP connector. The button can only recover rows present in an accessible local database, backup, or separately obtained export. There is no documented bulk account-history export format to build against today.

## Phase 1 — source snapshot and preview

1. Add a macOS source reader near `Sources/Inlay/` that discovers `~/Library/Application Support/Wispr Flow/flow.sqlite` and inspects `History` and `Dictionary` by column name. Do not assume every installed Wispr Flow version has the same columns. A manually chosen `.sqlite` file can be added later.
2. Take a consistent **read-only SQLite snapshot** into Inlay's private temporary directory before parsing. Prefer SQLite's backup API; handle a live WAL correctly and report snapshot failures rather than silently reading an inconsistent file. Never write into Wispr Flow's application-support directory.
3. Build a preview with the source date range and separate counts for nonempty transcripts, empty-text/failed attempts, WAV audio, screenshots, dictionary entries, and already-imported source IDs. Show estimated transfer/storage bytes and the chosen destination server. Build the preview locally; a server deduplication check sends source IDs only, without transcript or context data.
4. Scan complete Wispr Flow backups as well as the live database. Key rows by `transcriptEntityId`; prefer the current row for display and fill missing fields/media from older rows. A backup can restore media even when it adds no session IDs. Retain source row variants with their database provenance. Ignore incomplete `.tmp` backup files.

The source reader should iterate rows rather than loading all media blobs at once. `History.audio` is a WAV blob and `History.screenshot` is a PNG blob when present; validate actual file headers, format, and size before archiving. Preserve `opusChunks` even when WAV audio is also present.

## Phase 2 — faithful archival record

Extend [`GenerationRecord`](../Sources/InlayAPI/API.swift) with an optional source descriptor. Keep the existing live-recording fields compatible with old metadata; source status and settings must be labeled as **Wispr Flow source data**, not presented as Inlay inference details. Imported records must be excluded from recording continuation and delivery logic.

```swift
struct ImportedSource: Codable, Equatable, Sendable {
    var provider: String          // "wispr-flow"
    var sourceID: UUID            // History.transcriptEntityId
    var sourceStatus: String?
    var importedAt: Date
    var variantNames: [String]
    var artifactNames: [WisprFlowArtifactName]
}
```

For the default History text, use nonempty `pastedText` (what Flow inserted), falling back to `serverFinalizedText`, `formattedText`, then `asrText`. Preserve available text variants, edits, timing, language, app/URL, quality/feedback, and unknown source columns in a separate `source.json` artifact so later code can remap them. Keep SQLite value types and nulls; encode binary values as base64 when they fit. This avoids bloating Inlay's `metadata.json`, which startup limits to 1 MiB. A row with no usable text or audio remains a labeled metadata-only source attempt.

Each uploaded artifact, including `source.json`, is limited to 8 MiB; the archived dictionary JSON has the same limit and stops encoding before it grows beyond that bound. Inlay keeps one canonical WAV, Opus JSON, and PNG attachment per session and tries an older valid version if the newest media exceeds the limit. `source.json` records each oversized, invalid, unavailable, or different backup media version with its source row, byte count, SHA-256 digest, and archive status; those alternate bytes are not stored. The recognized `builtInAudio` blob is recorded by hash and size only, and the session is marked partial. A rerun with different media preserves the earlier attachment and reports a partial import.

The reader keeps `source.json` within the upload limit by replacing oversized source values with type, size, hash, and reason. If that is still too large, it summarizes older rows or detailed omission records with counts and aggregate hashes while keeping the selected transcript in the record. These imports are marked partial. An extreme enrichment that merges two near-limit source documents can still exceed the server's 8 MiB bound; the earlier archive remains intact and that enrichment reports failure.

Keep Wispr Flow dictionary state as an import artifact. Any change to Inlay's active dictionary should be a separate previewed merge, because it changes future dictations and Inlay's dictionary has its own limits and conflict rules.

## Phase 3 — server import path and safe reruns

Add authenticated import routes in [`InlayHTTPServer.swift`](../Sources/InlayServerKit/InlayHTTPServer.swift) and archival writes in [`GenerationService.swift`](../Sources/InlayServerKit/GenerationService.swift). The existing `POST /v1/generations` and audio/finish routes require a live recording and model readiness, so they must not be reused for historical rows. The server cannot open a client-side Wispr Flow path, especially when it runs on another machine.

Use a bounded per-session protocol: send a small manifest and display text, upload allowlisted files with byte counts/checksums, then commit. Validate source ID, dates, text sizes, file signatures, attachment limits, and checksums on the server. Place files in a private staging directory, write metadata last, atomically move the complete directory under `generations/<UUID>/`, then publish it in memory. Extend the artifact endpoint's allowlist for typed imported files; never accept arbitrary filesystem paths from the client.

Index `(provider, sourceID)` at server startup. Repeated imports skip unchanged records and **enrich** existing imports when a later source supplies more fields or media; they never remove already archived data merely because it disappeared from Flow. Show imported, enriched, skipped, partial, and failed counts with a source ID for the first failure so an interrupted run can resume. Keep import-run diagnostics free of transcript text and source context.

## Phase 4 — History UX and verification

Add the button, preview sheet, progress/cancel state, and import summary to [`HistoryPage.swift`](../Sources/Inlay/Views/HistoryPage.swift), with orchestration in [`InlayController.swift`](../Sources/Inlay/InlayController.swift) and transport in [`ServerClient.swift`](../Sources/Inlay/ServerClient.swift). Show an **Imported from Wispr Flow** label, source text variants, and available attachment actions in detail. Add a source filter so imported sessions remain findable among the existing 50-record History pages. Cancellation releases the sheet immediately while background extraction stops and cleans its snapshot. Keep the list's dimensions steady while preview/progress changes.

Use computer use to inspect import previews against read-only local snapshots, including text-only rows, audio rows, metadata-only attempts, duplicate IDs, and reruns that enrich rather than duplicate. Only import into an isolated development archive. Run static checks and compile the client; automated tests and fixtures are not allowed.

## Recovery boundary

The normal button can archive only data still present in the selected local source files. Deleted rows, sessions from another device, and earlier account history require an older device database, an existing WisprSync export, or a support-provided account data copy. Wispr Flow does not publish a guaranteed bulk dictation-export format, so support-data ingestion should be designed after a real file is available. SQLite free pages are not a reliable source for the button.

Source references: [WisprSync's SQLite reader](https://github.com/fjooord/WisprSync/blob/8f24c4af5042fbb4d2d1de2348e8dd07b6aafc1a/wisprsync/source/sqlite.py), [source field/media shape](https://github.com/fjooord/WisprSync/blob/8f24c4af5042fbb4d2d1de2348e8dd07b6aafc1a/docs/10-system-design/10-data-structure/10-wispr-flow-source-shape.md), [Wispr Flow's local-history sync guide](https://docs.wisprflow.ai/articles/5284722493-sync-flow-across-your-devices), and [account-data access notice](https://wisprflow.ai/ccpa-notice).
