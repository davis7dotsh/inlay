import CryptoKit
import Foundation
import SQLite3
import InlayAPI

struct WisprFlowImportPreview: Sendable {
    let sessionCount: Int
    let transcriptCount: Int
    let metadataOnlyCount: Int
    let wavCount: Int
    let opusCount: Int
    let screenshotCount: Int
    let dictionaryCount: Int
    let earliestDate: Date?
    let latestDate: Date?
    let estimatedArtifactBytes: Int64
    let sourceURLs: [URL]
    let warnings: [String]
}

struct WisprFlowSourceArtifact: Sendable {
    let filename: WisprFlowArtifactName
    let url: URL
    let contentType: String
}

struct WisprFlowSourceSession: Sendable {
    let sourceID: UUID
    let createdAt: Date
    let displayText: String
    let rawText: String
    let sourceStatus: String?
    let durationSeconds: Double?
    let availableVariants: [String]
    let artifacts: [WisprFlowSourceArtifact]
    let unarchivedArtifacts: [WisprFlowArtifactManifest]
    let provenanceWarning: String?
}

enum WisprFlowSourceReaderError: LocalizedError {
    case noSources
    case unreadableSource(URL)
    case missingHistory(URL)
    case missingSourceID(URL)
    case invalidTimestamp(UUID)
    case missingSession(UUID)
    case sqlite(String)
    case cannotCreateArtifact(URL)
    case dictionaryTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .noSources: "No Wispr Flow database was found on this Mac."
        case .unreadableSource(let url): "Cannot read \(url.lastPathComponent)."
        case .missingHistory(let url): "\(url.lastPathComponent) has no History table."
        case .missingSourceID(let url): "\(url.lastPathComponent) has no transcriptEntityId column."
        case .invalidTimestamp(let id): "Wispr Flow session \(id) has no usable timestamp."
        case .missingSession(let id): "Wispr Flow session \(id) was not found in the snapshot."
        case .sqlite(let message): "Wispr Flow database error: \(message)"
        case .cannotCreateArtifact(let url): "Cannot create import artifact \(url.lastPathComponent)."
        case .dictionaryTooLarge(let bytes):
            "Wispr Flow dictionary archive exceeds the 8 MiB limit (at least \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))). No dictionary entries were archived."
        }
    }
}

/// The source databases are opened read-only. SQLite's backup API copies a consistent
/// view, including a live WAL, into private temporary files before any row is read.
/// The reader owns those files and the lazily extracted artifacts until deinit.
final class WisprFlowSourceReader: @unchecked Sendable {
    private struct RowLocator {
        let databaseIndex: Int
        let rowID: Int64
        let timestamp: Date?
        let sourceStatus: String?
        let displayText: String
        let rawText: String
        let durationSeconds: Double?
        let mediaBytes: [String: Int64]
    }

    private final class Database {
        let sourceURL: URL
        let snapshotURL: URL
        let role: String
        let columns: Set<String>
        let dictionaryColumns: Set<String>
        let connection: OpaquePointer

        init(sourceURL: URL, snapshotURL: URL, role: String, connection: OpaquePointer,
             columns: Set<String>, dictionaryColumns: Set<String>) {
            self.sourceURL = sourceURL
            self.snapshotURL = snapshotURL
            self.role = role
            self.connection = connection
            self.columns = columns
            self.dictionaryColumns = dictionaryColumns
        }

        deinit { sqlite3_close_v2(connection) }
    }

    private static let mediaFilenames = [
        "audio": "source.wav",
        "opusChunks": "opus.json",
        "screenshot": "screenshot.png",
    ]
    private static let mediaContentTypes = [
        "source.wav": "audio/wav",
        "opus.json": "application/json",
        "screenshot.png": "image/png",
        "source.json": "application/json",
    ]
    private static let textVariantNames = [
        "pastedText", "serverFinalizedText", "formattedText", "asrText",
        "editedText", "editedTextUnbounded", "toneMatchedText",
        "defaultAsrText", "fallbackAsrText", "defaultFormattedText",
        "fallbackFormattedText", "desiredAsr", "desiredFormatted",
    ]
    // Leave room for the server to add archive reconciliation details.
    private static let sourceJSONTargetBytes = WisprFlowImportLimits.maximumArtifactBytes - 1_048_576

    let preview: WisprFlowImportPreview
    let sourceIDs: [UUID]
    private let temporaryDirectory: URL
    private let lock = NSLock()
    private var databases: [Database]
    private var closed = false
    private let locators: [UUID: [RowLocator]]

    static func discoverSourceURLs() -> [URL] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow", isDirectory: true)
        let live = directory.appendingPathComponent("flow.sqlite")
        let backupsDirectory = directory.appendingPathComponent("backups", isDirectory: true)
        let backups = ((try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { url in
                url.lastPathComponent.hasPrefix("backup-") && url.pathExtension == "sqlite"
                    && ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        return (FileManager.default.isReadableFile(atPath: live.path) ? [live] : []) + backups
    }

    init(sourceURLs: [URL]? = nil) throws {
        let selected = sourceURLs ?? Self.discoverSourceURLs()
        guard !selected.isEmpty else { throw WisprFlowSourceReaderError.noSources }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Inlay-WisprFlow-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        temporaryDirectory = directory
        var opened: [Database] = []
        var rows: [UUID: [RowLocator]] = [:]
        var warnings: [String] = []
        var skippedMalformedIDs = 0
        do {
            for (index, source) in selected.enumerated() {
                guard source.pathExtension == "sqlite", !source.lastPathComponent.contains(".tmp"),
                      FileManager.default.isReadableFile(atPath: source.path) else {
                    throw WisprFlowSourceReaderError.unreadableSource(source)
                }
                let snapshot = directory.appendingPathComponent("source-\(index).sqlite")
                try Self.snapshot(source: source, destination: snapshot)
                let connection = try Self.openDatabase(snapshot, flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                                                       immutable: true)
                let database: Database
                do {
                    try Self.quickCheck(connection)
                    let columns = try Self.columns(in: "History", database: connection)
                    guard !columns.isEmpty else { throw WisprFlowSourceReaderError.missingHistory(source) }
                    guard columns.contains("transcriptEntityId") else {
                        throw WisprFlowSourceReaderError.missingSourceID(source)
                    }
                    let dictionaryColumns = try Self.columns(in: "Dictionary", database: connection)
                    let role = source.lastPathComponent == "flow.sqlite" ? "current"
                        : (source.lastPathComponent.hasPrefix("backup-") ? "backup" : "selected")
                    database = Database(sourceURL: source, snapshotURL: snapshot, role: role,
                                        connection: connection, columns: columns,
                                        dictionaryColumns: dictionaryColumns)
                } catch {
                    sqlite3_close_v2(connection)
                    throw error
                }
                opened.append(database)
                let scanned = try Self.scan(database: database, index: index)
                skippedMalformedIDs += scanned.skippedMalformedIDs
                for row in scanned.rows {
                    rows[row.0, default: []].append(row.1)
                }
            }
            let ids = rows.keys.sorted { left, right in
                let leftDate = rows[left]?.compactMap(\.timestamp).first ?? .distantPast
                let rightDate = rows[right]?.compactMap(\.timestamp).first ?? .distantPast
                return leftDate == rightDate ? left.uuidString < right.uuidString : leftDate < rightDate
            }
            let entries = ids.compactMap { rows[$0] }
            let dated = entries.compactMap { $0.compactMap(\.timestamp).first }
            let transcriptCount = entries.filter { entry in
                entry.contains { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }.count
            let wavCount = entries.filter { Self.hasMedia("audio", in: $0) }.count
            let opusCount = entries.filter { Self.hasMedia("opusChunks", in: $0) }.count
            let screenshotCount = entries.filter { Self.hasMedia("screenshot", in: $0) }.count
            let metadataOnlyCount = entries.filter { entry in
                !entry.contains { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    && !Self.hasMedia("audio", in: entry) && !Self.hasMedia("opusChunks", in: entry)
            }.count
            let mediaBytes = entries.reduce(Int64(0)) { total, entry in
                total + Self.mediaFilenames.keys.reduce(Int64(0)) { amount, column in
                    amount + (entry.first { ($0.mediaBytes[column] ?? 0) > 0 }?.mediaBytes[column] ?? 0)
                }
            }
            if dated.count < ids.count { warnings.append("Some sessions have no usable timestamp and may fail to import.") }
            if skippedMalformedIDs > 0 {
                warnings.append("Skipped \(skippedMalformedIDs) History row\(skippedMalformedIDs == 1 ? "" : "s") with missing or malformed session IDs.")
            }
            let dictionaryCount = try Self.dictionaryCount(in: opened)
            preview = WisprFlowImportPreview(
                sessionCount: ids.count, transcriptCount: transcriptCount,
                metadataOnlyCount: metadataOnlyCount, wavCount: wavCount,
                opusCount: opusCount, screenshotCount: screenshotCount,
                dictionaryCount: dictionaryCount, earliestDate: dated.min(), latestDate: dated.max(),
                estimatedArtifactBytes: mediaBytes + Int64(ids.count) * 16_384,
                sourceURLs: selected, warnings: warnings
            )
            sourceIDs = ids
            locators = rows
            databases = opened
        } catch {
            opened.removeAll()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { close() }

    /// Closing snapshots can take time. The controller calls this on a utility
    /// task before releasing its last reader reference.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        databases.removeAll()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func session(for sourceID: UUID) throws -> WisprFlowSourceSession {
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        guard !closed else { throw WisprFlowSourceReaderError.sqlite("The import snapshot was released.") }
        guard let rows = locators[sourceID], !rows.isEmpty else {
            throw WisprFlowSourceReaderError.missingSession(sourceID)
        }
        guard let createdAt = rows.compactMap(\.timestamp).first else {
            throw WisprFlowSourceReaderError.invalidTimestamp(sourceID)
        }
        let displayText = rows.first {
            !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.displayText ?? ""
        let rawText = rows.first {
            !$0.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.rawText ?? ""
        let sourceStatus = rows.compactMap(\.sourceStatus).first
        let durationSeconds = rows.compactMap(\.durationSeconds).first
        let artifactDirectory = temporaryDirectory.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: artifactDirectory.path) {
            try FileManager.default.removeItem(at: artifactDirectory)
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
        var artifacts: [WisprFlowSourceArtifact] = []
        var selectedMedia: [String: (databaseIndex: Int, rowID: Int64)] = [:]
        for (column, filename) in Self.mediaFilenames {
            try Task.checkCancellation()
            for row in rows where (row.mediaBytes[column] ?? 0) > 0 {
                try Task.checkCancellation()
                // A later backup may contain a smaller valid version. Keep
                // looking rather than letting one oversized blob block text.
                guard (row.mediaBytes[column] ?? 0) <= WisprFlowImportLimits.maximumArtifactBytes else { continue }
                let output = artifactDirectory.appendingPathComponent(filename)
                do {
                    try Self.extract(column: column, rowID: row.rowID,
                                     from: databases[row.databaseIndex].connection, to: output)
                    try Task.checkCancellation()
                    guard try Self.isValidArtifact(output, filename: filename) else {
                        try? FileManager.default.removeItem(at: output)
                        continue
                    }
                    selectedMedia[column] = (row.databaseIndex, row.rowID)
                    guard let artifactName = WisprFlowArtifactName(rawValue: filename) else { continue }
                    artifacts.append(WisprFlowSourceArtifact(
                        filename: artifactName, url: output,
                        contentType: Self.mediaContentTypes[filename] ?? "application/octet-stream"
                    ))
                    break
                } catch is CancellationError {
                    try? FileManager.default.removeItem(at: output)
                    throw CancellationError()
                } catch {
                    try? FileManager.default.removeItem(at: output)
                    continue
                }
            }
        }
        var sources: [[String: Any]] = []
        var variants = Set<String>()
        var provenanceOmittedFieldCount = 0
        for row in rows {
            try Task.checkCancellation()
            let database = databases[row.databaseIndex]
            let values = try Self.sourceValues(for: row, in: database, selectedMedia: selectedMedia,
                                               omittedFieldCount: &provenanceOmittedFieldCount)
            try Task.checkCancellation()
            for name in Self.textVariantNames {
                if let field = values[name], field["type"] as? String == "text",
                   (field["archiveStatus"] as? String == "not-archived"
                    || (field["value"] as? String).map({
                        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) == true) {
                    variants.insert(name)
                }
            }
            sources.append([
                "name": database.sourceURL.lastPathComponent,
                "role": database.role,
                "rowID": row.rowID,
                "values": values,
            ])
        }
        var selectedHashes: [String: String] = [:]
        for source in sources {
            try Task.checkCancellation()
            guard let values = source["values"] as? [String: [String: Any]] else { continue }
            for (column, filename) in Self.mediaFilenames {
                if values[column]?["artifact"] as? String == filename,
                   let hash = values[column]?["sha256"] as? String {
                    selectedHashes[column] = hash
                }
            }
        }
        var omissions: [[String: Any]] = []
        var unarchived: [WisprFlowArtifactManifest] = []
        var seenMissing = Set<String>()
        for index in sources.indices {
            try Task.checkCancellation()
            guard var values = sources[index]["values"] as? [String: [String: Any]] else { continue }
            for (column, filename) in Self.mediaFilenames {
                guard var field = values[column], let byteCount = field["byteCount"] as? Int,
                      byteCount > 0, let hash = field["sha256"] as? String else { continue }
                if selectedHashes[column] == hash {
                    field["artifact"] = filename
                    field["archiveStatus"] = "archived"
                } else {
                    let reason = byteCount > WisprFlowImportLimits.maximumArtifactBytes ? "exceeds-upload-limit"
                        : selectedHashes[column] == nil ? "invalid-or-unavailable" : "different-source-version"
                    field["archiveStatus"] = "not-archived"
                    field["archiveReason"] = reason
                    omissions.append([
                        "artifact": filename, "sourceIndex": index,
                        "sourceName": sources[index]["name"] as? String ?? "unknown",
                        "sourceRowID": sources[index]["rowID"] as? Int64 ?? 0,
                        "observedByteCount": byteCount, "observedSHA256": hash,
                        "reason": reason, "status": "not-archived",
                    ])
                    let key = "\(filename):\(hash)"
                    if seenMissing.insert(key).inserted,
                       let name = WisprFlowArtifactName(rawValue: filename) {
                        unarchived.append(WisprFlowArtifactManifest(
                            filename: name, byteCount: byteCount, sha256: hash))
                    }
                }
                values[column] = field
            }
            if var builtIn = values["builtInAudio"],
               let byteCount = builtIn["byteCount"] as? Int, byteCount > 0,
               let hash = builtIn["sha256"] as? String {
                builtIn["archiveStatus"] = "not-archived"
                builtIn["archiveReason"] = "unsupported-source-column"
                omissions.append([
                    "artifact": WisprFlowArtifactName.builtInAudio.rawValue,
                    "sourceColumn": "builtInAudio", "sourceIndex": index,
                    "sourceName": sources[index]["name"] as? String ?? "unknown",
                    "sourceRowID": sources[index]["rowID"] as? Int64 ?? 0,
                    "observedByteCount": byteCount, "observedSHA256": hash,
                    "reason": "unsupported-source-column", "status": "not-archived",
                ])
                let key = "builtInAudio:\(hash)"
                if seenMissing.insert(key).inserted {
                    unarchived.append(WisprFlowArtifactManifest(
                        filename: .builtInAudio, byteCount: byteCount, sha256: hash))
                }
                values["builtInAudio"] = builtIn
            }
            sources[index]["values"] = values
        }
        let bounded = try Self.boundedSourceJSON(
            sourceID: sourceID, sources: sources, omissions: omissions,
            unarchived: unarchived, initiallyOmittedFields: provenanceOmittedFieldCount
        )
        try Task.checkCancellation()
        let sourceURL = artifactDirectory.appendingPathComponent("source.json")
        try bounded.data.write(to: sourceURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
        artifacts.insert(WisprFlowSourceArtifact(filename: .sourceJSON, url: sourceURL,
                                                contentType: "application/json"), at: 0)
        return WisprFlowSourceSession(
            sourceID: sourceID, createdAt: createdAt, displayText: displayText,
            rawText: rawText, sourceStatus: sourceStatus,
            durationSeconds: durationSeconds,
            availableVariants: Self.textVariantNames.filter { variants.contains($0) },
            artifacts: artifacts, unarchivedArtifacts: bounded.unarchived,
            provenanceWarning: bounded.warning
        )
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw error
        }
    }

    func dictionaryArtifactURL() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw WisprFlowSourceReaderError.sqlite("The import snapshot was released.") }
        guard preview.dictionaryCount > 0 else { return nil }
        let url = temporaryDirectory.appendingPathComponent("dictionary.json")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let limit = WisprFlowImportLimits.maximumDictionaryBytes
        var archive = Data()
        archive.reserveCapacity(min(limit, 262_144))
        try Self.appendDictionaryJSON(Data(#"{"provider":"wispr-flow","schemaVersion":1,"sources":["#.utf8),
                                      to: &archive, limit: limit)
        var firstSource = true
        for database in databases where !database.dictionaryColumns.isEmpty {
            if !firstSource { try Self.appendDictionaryJSON(Data(",".utf8), to: &archive, limit: limit) }
            firstSource = false
            let header = try JSONSerialization.data(withJSONObject: [
                "name": database.sourceURL.lastPathComponent, "role": database.role,
            ], options: [.sortedKeys])
            try Self.appendDictionaryJSON(Data(header.dropLast()), to: &archive, limit: limit)
            try Self.appendDictionaryJSON(Data(#","rows":["#.utf8), to: &archive, limit: limit)
            let sql = "SELECT * FROM \"Dictionary\""
            let statement = try Self.prepare(sql, in: database.connection)
            defer { sqlite3_finalize(statement) }
            let columns = (0..<sqlite3_column_count(statement)).map { column in
                (column, String(cString: sqlite3_column_name(statement, column)))
            }.sorted { $0.1 < $1.1 }
            var firstRow = true
            while try Self.nextRow(statement, in: database.connection) {
                if !firstRow { try Self.appendDictionaryJSON(Data(",".utf8), to: &archive, limit: limit) }
                firstRow = false
                try Self.appendDictionaryJSON(Data("{".utf8), to: &archive, limit: limit)
                for (index, entry) in columns.enumerated() {
                    if index > 0 { try Self.appendDictionaryJSON(Data(",".utf8), to: &archive, limit: limit) }
                    try Self.appendDictionaryJSON(JSONEncoder().encode(entry.1), to: &archive, limit: limit)
                    try Self.appendDictionaryJSON(Data(":".utf8), to: &archive, limit: limit)
                    try Self.appendDictionaryValue(statement, column: entry.0, to: &archive, limit: limit)
                }
                try Self.appendDictionaryJSON(Data("}".utf8), to: &archive, limit: limit)
            }
            try Self.appendDictionaryJSON(Data("]}".utf8), to: &archive, limit: limit)
        }
        try Self.appendDictionaryJSON(Data(#"],"table":"Dictionary"}"#.utf8), to: &archive, limit: limit)
        try archive.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func appendDictionaryJSON(_ chunk: Data, to archive: inout Data, limit: Int) throws {
        guard chunk.count <= limit - archive.count else {
            throw WisprFlowSourceReaderError.dictionaryTooLarge(archive.count + chunk.count)
        }
        archive.append(chunk)
    }

    private static func appendDictionaryValue(_ statement: OpaquePointer, column: Int32,
                                              to archive: inout Data, limit: Int) throws {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count <= limit - archive.count else {
                throw WisprFlowSourceReaderError.dictionaryTooLarge(archive.count + count)
            }
            guard let pointer = sqlite3_column_text(statement, column) else {
                try appendDictionaryJSON(Data(#"{"type":"text","value":""}"#.utf8), to: &archive, limit: limit)
                return
            }
            let bytes = Data(bytes: pointer, count: count)
            if let text = String(data: bytes, encoding: .utf8) {
                try appendDictionaryJSON(Data(#"{"type":"text","value":"#.utf8), to: &archive, limit: limit)
                try appendDictionaryString(text, to: &archive, limit: limit)
                try appendDictionaryJSON(Data("}".utf8), to: &archive, limit: limit)
            } else {
                let base64Length = ((count + 2) / 3) * 4
                guard base64Length <= limit - archive.count else {
                    throw WisprFlowSourceReaderError.dictionaryTooLarge(archive.count + base64Length)
                }
                try appendDictionaryJSON(Data(#"{"base64":""#.utf8), to: &archive, limit: limit)
                try appendDictionaryJSON(Data(bytes.base64EncodedString().utf8), to: &archive, limit: limit)
                try appendDictionaryJSON(Data(#"","encoding":"raw-bytes","type":"text"}"#.utf8),
                                         to: &archive, limit: limit)
            }
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            let base64Length = ((count + 2) / 3) * 4
            guard base64Length <= limit - archive.count else {
                throw WisprFlowSourceReaderError.dictionaryTooLarge(archive.count + base64Length)
            }
            try appendDictionaryJSON(Data(#"{"base64":""#.utf8), to: &archive, limit: limit)
            if let pointer = sqlite3_column_blob(statement, column) {
                let bytes = Data(bytes: pointer, count: count)
                try appendDictionaryJSON(Data(bytes.base64EncodedString().utf8), to: &archive, limit: limit)
            }
            try appendDictionaryJSON(Data(#"","type":"blob"}"#.utf8), to: &archive, limit: limit)
        default:
            let value = typedValue(statement, column: column)
            try appendDictionaryJSON(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                                     to: &archive, limit: limit)
        }
    }

    private static func appendDictionaryString(_ string: String, to archive: inout Data, limit: Int) throws {
        let hex = Array("0123456789abcdef".utf8)
        var buffer = Data()
        buffer.reserveCapacity(4_096)
        try appendDictionaryJSON(Data("\"".utf8), to: &archive, limit: limit)
        for byte in string.utf8 {
            switch byte {
            case 0x22, 0x5c: buffer.append(contentsOf: [0x5c, byte])
            case 0x08: buffer.append(contentsOf: [0x5c, 0x62])
            case 0x09: buffer.append(contentsOf: [0x5c, 0x74])
            case 0x0a: buffer.append(contentsOf: [0x5c, 0x6e])
            case 0x0c: buffer.append(contentsOf: [0x5c, 0x66])
            case 0x0d: buffer.append(contentsOf: [0x5c, 0x72])
            case 0x00...0x1f:
                buffer.append(contentsOf: [0x5c, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0f)]])
            default: buffer.append(byte)
            }
            if buffer.count >= 4_096 {
                try appendDictionaryJSON(buffer, to: &archive, limit: limit)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try appendDictionaryJSON(buffer, to: &archive, limit: limit) }
        try appendDictionaryJSON(Data("\"".utf8), to: &archive, limit: limit)
    }

    func deleteArtifacts(for sourceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: temporaryDirectory.appendingPathComponent(sourceID.uuidString))
    }

    func discardArtifacts(for session: WisprFlowSourceSession) {
        deleteArtifacts(for: session.sourceID)
    }

    private static func hasMedia(_ column: String, in rows: [RowLocator]) -> Bool {
        rows.contains { ($0.mediaBytes[column] ?? 0) > 0 }
    }

    private static func openDatabase(_ url: URL, flags: Int32, immutable: Bool = false) throws -> OpaquePointer {
        var connection: OpaquePointer?
        let address = immutable ? url.absoluteString + "?immutable=1" : url.path
        let result = sqlite3_open_v2(address, &connection, flags | (immutable ? SQLITE_OPEN_URI : 0), nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            if let connection { sqlite3_close_v2(connection) }
            throw WisprFlowSourceReaderError.sqlite("\(url.lastPathComponent): \(message)")
        }
        sqlite3_busy_timeout(connection, 5_000)
        return connection
    }

    private static func snapshot(source: URL, destination: URL) throws {
        // Never ask SQLite to open a live WAL inside Wispr Flow's directory: even
        // SQLITE_OPEN_READONLY may create a missing -shm file there. Copy its main
        // file and WAL by read-only filesystem reads, then let SQLite use private
        // temporary sidecars. A source without WAL is a fixed immutable main file.
        let sourceWAL = URL(fileURLWithPath: source.path + "-wal")
        let hasWAL = FileManager.default.fileExists(atPath: sourceWAL.path)
        let beforeMain = try FileManager.default.attributesOfItem(atPath: source.path)
        let beforeWAL = hasWAL ? try FileManager.default.attributesOfItem(atPath: sourceWAL.path) : nil
        let privateInput = destination.deletingPathExtension().appendingPathExtension("raw.sqlite")
        if hasWAL {
            try FileManager.default.copyItem(at: source, to: privateInput)
            try FileManager.default.copyItem(at: sourceWAL,
                                             to: URL(fileURLWithPath: privateInput.path + "-wal"))
        }
        defer {
            if hasWAL {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: privateInput.path + suffix))
                }
            }
        }
        let input = try openDatabase(hasWAL ? privateInput : source,
                                     flags: (hasWAL ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX,
                                     immutable: !hasWAL)
        defer { sqlite3_close_v2(input) }
        let output = try openDatabase(destination, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        defer { sqlite3_close_v2(output) }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw WisprFlowSourceReaderError.sqlite(
                "Cannot snapshot \(source.lastPathComponent): \(String(cString: sqlite3_errmsg(output))) / \(String(cString: sqlite3_errmsg(input)))"
            )
        }
        var result: Int32 = SQLITE_OK
        var busyAttempts = 0
        repeat {
            result = sqlite3_backup_step(backup, 256)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                busyAttempts += 1
                if busyAttempts < 50 { sqlite3_sleep(100) }
            }
        } while result == SQLITE_OK || ((result == SQLITE_BUSY || result == SQLITE_LOCKED) && busyAttempts < 50)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw WisprFlowSourceReaderError.sqlite(
                "Cannot finish snapshot \(source.lastPathComponent): \(String(cString: sqlite3_errmsg(output))) / \(String(cString: sqlite3_errmsg(input)))"
            )
        }
        let afterMain = try FileManager.default.attributesOfItem(atPath: source.path)
        let afterHasWAL = FileManager.default.fileExists(atPath: sourceWAL.path)
        let afterWAL = afterHasWAL ? try FileManager.default.attributesOfItem(atPath: sourceWAL.path) : nil
        guard sameFileState(beforeMain, afterMain), hasWAL == afterHasWAL,
              (!hasWAL || sameFileState(beforeWAL, afterWAL)) else {
            throw WisprFlowSourceReaderError.sqlite(
                "\(source.lastPathComponent) changed during its read-only snapshot. Pause Wispr Flow dictation and retry."
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func sameFileState(_ first: [FileAttributeKey: Any]?,
                                      _ second: [FileAttributeKey: Any]?) -> Bool {
        guard let first, let second else { return first == nil && second == nil }
        return (first[.size] as? NSNumber) == (second[.size] as? NSNumber)
            && (first[.modificationDate] as? Date) == (second[.modificationDate] as? Date)
            && (first[.systemFileNumber] as? NSNumber) == (second[.systemFileNumber] as? NSNumber)
    }

    private static func quickCheck(_ database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA quick_check", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, text(statement, column: 0) == "ok" else {
            throw WisprFlowSourceReaderError.sqlite("Snapshot integrity check failed.")
        }
    }

    private static func columns(in table: String, database: OpaquePointer) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\"\(table)\")", in: database)
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while try nextRow(statement, in: database) {
            if let name = text(statement, column: 1) { names.insert(name) }
        }
        return names
    }

    private static func scan(database: Database, index: Int) throws
        -> (rows: [(UUID, RowLocator)], skippedMalformedIDs: Int) {
        func field(_ name: String) -> String {
            database.columns.contains(name) ? "\"\(name)\"" : "NULL"
        }
        func length(_ name: String) -> String {
            database.columns.contains(name)
                ? "CASE WHEN typeof(\"\(name)\") IN ('blob', 'text') THEN length(CAST(\"\(name)\" AS BLOB)) ELSE 0 END"
                : "0"
        }
        let sql = """
            SELECT rowid, \(field("transcriptEntityId")), \(field("timestamp")),
                   \(field("pastedText")), \(field("serverFinalizedText")),
                   \(field("formattedText")), \(field("asrText")),
                   \(field("status")), \(field("duration")), \(field("speechDuration")),
                   \(length("audio")), \(length("opusChunks")), \(length("screenshot"))
            FROM "History"
            """
        let statement = try prepare(sql, in: database.connection)
        defer { sqlite3_finalize(statement) }
        var rows: [(UUID, RowLocator)] = []
        var skippedMalformedIDs = 0
        while try nextRow(statement, in: database.connection) {
            let idText = text(statement, column: 1) ?? ""
            guard let id = UUID(uuidString: idText) else {
                skippedMalformedIDs += 1
                continue
            }
            let candidates = (3...6).compactMap { text(statement, column: Int32($0)) }
            let display = candidates.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
            let duration = number(statement, column: 8) ?? number(statement, column: 9)
            let media = [
                "audio": sqlite3_column_int64(statement, 10),
                "opusChunks": sqlite3_column_int64(statement, 11),
                "screenshot": sqlite3_column_int64(statement, 12),
            ]
            rows.append((id, RowLocator(
                databaseIndex: index, rowID: sqlite3_column_int64(statement, 0),
                timestamp: text(statement, column: 2).flatMap(parseDate),
                sourceStatus: text(statement, column: 7), displayText: display,
                rawText: text(statement, column: 6) ?? "",
                durationSeconds: duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
                mediaBytes: media
            )))
        }
        return (rows, skippedMalformedIDs)
    }

    private static func dictionaryCount(in databases: [Database]) throws -> Int {
        var ids = Set<String>()
        var rowsWithoutUsableID = 0
        for database in databases where !database.dictionaryColumns.isEmpty {
            let idExpression = database.dictionaryColumns.contains("id") ? "CAST(\"id\" AS TEXT)" : "NULL"
            let statement = try prepare("SELECT \(idExpression) FROM \"Dictionary\"", in: database.connection)
            defer { sqlite3_finalize(statement) }
            while try nextRow(statement, in: database.connection) {
                if let id = text(statement, column: 0), !id.isEmpty {
                    ids.insert(id)
                } else {
                    // These rows still have data to archive, but cannot be
                    // deduplicated reliably across snapshots.
                    rowsWithoutUsableID += 1
                }
            }
        }
        return ids.count + rowsWithoutUsableID
    }

    private static func sourceValues(
        for row: RowLocator, in database: Database,
        selectedMedia: [String: (databaseIndex: Int, rowID: Int64)],
        omittedFieldCount: inout Int
    ) throws -> [String: [String: Any]] {
        let statement = try prepare("SELECT * FROM \"History\" WHERE rowid = ?", in: database.connection)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, row.rowID)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw WisprFlowSourceReaderError.sqlite("A snapshotted History row disappeared.")
        }
        var values: [String: [String: Any]] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            if name == "audio" || name == "opusChunks" || name == "screenshot" || name == "builtInAudio" {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT, SQLITE_BLOB:
                    let type = sqliteType(sqlite3_column_type(statement, index))
                    var reference: [String: Any] = ["type": type, "byteCount": Int(sqlite3_column_bytes(statement, index))]
                    reference["sha256"] = try hashBlob(column: name, rowID: row.rowID,
                                                       from: database.connection)
                    if let selected = selectedMedia[name], selected.databaseIndex == row.databaseIndex,
                       selected.rowID == row.rowID, let filename = mediaFilenames[name] {
                        reference["artifact"] = filename
                    }
                    values[name] = reference
                default:
                    // SQLite's dynamic typing permits a numeric value even in
                    // a media-named column. It is source data, not blob bytes.
                    values[name] = typedValue(statement, column: index)
                }
            } else {
                let type = sqliteType(sqlite3_column_type(statement, index))
                // A single BLOB expands by a third when encoded as base64. A
                // single very large TEXT value also cannot fit in source.json.
                let maximumValueBytes = type == "blob" ? sourceJSONTargetBytes * 3 / 4
                    : sourceJSONTargetBytes
                let byteCount = (type == "blob" || type == "text")
                    ? Int(sqlite3_column_bytes(statement, index)) : 0
                if byteCount > maximumValueBytes {
                    values[name] = [
                        "type": type, "byteCount": byteCount,
                        "sha256": try hashBlob(column: name, rowID: row.rowID,
                                               from: database.connection),
                        "archiveStatus": "not-archived",
                        "archiveReason": "exceeds-source-json-limit",
                    ]
                    omittedFieldCount += 1
                } else {
                    values[name] = typedValue(statement, column: index)
                }
            }
        }
        return values
    }

    private struct BoundedSourceJSON {
        let data: Data
        let unarchived: [WisprFlowArtifactManifest]
        let warning: String?
    }

    private struct SourceValueCandidate {
        let sourceIndex: Int
        let column: String
        let approximateBytes: Int
        let priority: Int
    }

    private static func provenanceSummary(for field: [String: Any]) -> [String: Any]? {
        guard let type = field["type"] as? String, type == "text" || type == "blob" else { return nil }
        let bytes: Data
        if let value = field["value"] as? String {
            bytes = Data(value.utf8)
        } else if let base64 = field["base64"] as? String,
                  let decoded = Data(base64Encoded: base64) {
            bytes = decoded
        } else {
            return nil
        }
        var summary: [String: Any] = [
            "type": type, "byteCount": bytes.count,
            "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            "archiveStatus": "not-archived",
            "archiveReason": "exceeds-source-json-limit",
        ]
        if let encoding = field["encoding"] as? String { summary["encoding"] = encoding }
        return summary
    }

    private static func boundedSourceJSON(
        sourceID: UUID, sources originalSources: [[String: Any]],
        omissions originalOmissions: [[String: Any]],
        unarchived originalUnarchived: [WisprFlowArtifactManifest],
        initiallyOmittedFields: Int
    ) throws -> BoundedSourceJSON {
        var sources = originalSources
        var omissions = originalOmissions
        var omittedFields = initiallyOmittedFields
        var omittedSources = 0
        var omittedMediaVersions = 0
        var omittedColumns = 0
        var sourceHasher = SHA256()
        var mediaHasher = SHA256()

        func digest(_ hasher: SHA256) -> String {
            let copy = hasher
            return copy.finalize().map { String(format: "%02x", $0) }.joined()
        }
        func encode() throws -> Data {
            try Task.checkCancellation()
            var document: [String: Any] = [
                "schemaVersion": 1, "provider": "wispr-flow",
                "sourceID": sourceID.uuidString,
                "sources": sources, "archiveOmissions": omissions,
            ]
            if omittedFields + omittedSources + omittedMediaVersions + omittedColumns > 0 {
                document["provenanceStatus"] = "partial"
                document["provenanceOmittedFieldCount"] = omittedFields
                document["provenanceOmittedSourceCount"] = omittedSources
                document["provenanceOmittedMediaVersionCount"] = omittedMediaVersions
                if omittedColumns > 0 { document["provenanceOmittedColumnCount"] = omittedColumns }
                if omittedSources > 0 { document["provenanceOmittedSourcesSHA256"] = digest(sourceHasher) }
                if omittedMediaVersions > 0 {
                    document["provenanceOmittedMediaVersionsSHA256"] = digest(mediaHasher)
                }
            }
            return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        }

        var data = try encode()
        if data.count > sourceJSONTargetBytes {
            var candidates: [SourceValueCandidate] = []
            for (sourceIndex, source) in sources.enumerated() {
                guard let values = source["values"] as? [String: [String: Any]] else { continue }
                for (column, field) in values {
                    guard let type = field["type"] as? String, type == "text" || type == "blob" else { continue }
                    let approximateBytes = (field["base64"] as? String)?.utf8.count
                        ?? (field["value"] as? String)?.utf8.count ?? 0
                    guard approximateBytes > 0 else { continue }
                    let priority = type == "blob" ? 0 : (textVariantNames.contains(column) ? 2 : 1)
                    candidates.append(SourceValueCandidate(
                        sourceIndex: sourceIndex, column: column,
                        approximateBytes: approximateBytes, priority: priority
                    ))
                }
            }
            candidates.sort { left, right in
                if left.approximateBytes != right.approximateBytes {
                    return left.approximateBytes > right.approximateBytes
                }
                if left.priority != right.priority { return left.priority < right.priority }
                if left.sourceIndex != right.sourceIndex { return left.sourceIndex > right.sourceIndex }
                return left.column < right.column
            }
            for candidate in candidates where data.count > sourceJSONTargetBytes {
                guard var values = sources[candidate.sourceIndex]["values"] as? [String: [String: Any]],
                      let field = values[candidate.column],
                      let summary = provenanceSummary(for: field) else { continue }
                values[candidate.column] = summary
                sources[candidate.sourceIndex]["values"] = values
                omittedFields += 1
                data = try encode()
            }
        }

        // Backup versions are useful provenance, but the first/current row is
        // the canonical source of the session text and must remain recoverable.
        while data.count > sourceJSONTargetBytes && sources.count > 1 {
            let removed = sources.removeLast()
            sourceHasher.update(data: try JSONSerialization.data(withJSONObject: removed, options: [.sortedKeys]))
            sourceHasher.update(data: Data([0x0A]))
            omittedSources += 1
            data = try encode()
        }

        // The detailed media records are the last thing we compact. Keep the
        // first/current version's entries ahead of later backup versions.
        while data.count > sourceJSONTargetBytes && !omissions.isEmpty {
            let removed = omissions.removeLast()
            mediaHasher.update(data: try JSONSerialization.data(withJSONObject: removed, options: [.sortedKeys]))
            mediaHasher.update(data: Data([0x0A]))
            omittedMediaVersions += 1
            data = try encode()
        }

        if data.count > sourceJSONTargetBytes, var canonical = sources.first,
           let values = canonical["values"] as? [String: [String: Any]] {
            let columnNames = values.keys.sorted()
            let mediaColumns = Set(["audio", "opusChunks", "screenshot", "builtInAudio"])
            canonical["omittedValuesSHA256"] = SHA256.hash(data: try JSONSerialization.data(
                withJSONObject: values, options: [.sortedKeys]
            )).map { String(format: "%02x", $0) }.joined()
            canonical["columnNames"] = columnNames
            let omittedValueCount = values.count - mediaColumns.intersection(Set(values.keys)).count
            canonical["omittedValueCount"] = omittedValueCount
            canonical["values"] = values.filter { mediaColumns.contains($0.key) }
            omittedFields += values.filter {
                !mediaColumns.contains($0.key)
                    && $0.value["archiveReason"] as? String != "exceeds-source-json-limit"
            }.count
            // The server counts this row summary as omittedValueCount, even
            // when some fields were already summarized earlier in this pass.
            omittedFields = max(omittedFields, omittedValueCount)
            sources[0] = canonical
            data = try encode()
        }

        while data.count > sourceJSONTargetBytes, var canonical = sources.first,
              var names = canonical["columnNames"] as? [String], !names.isEmpty {
            names.removeLast()
            canonical["columnNames"] = names
            canonical["omittedColumnCount"] = omittedColumns + 1
            sources[0] = canonical
            omittedColumns += 1
            omittedFields += 1
            data = try encode()
        }

        // A malformed source can still have unusually large column metadata.
        // This final form preserves the canonical row locator and an aggregate
        // digest, so the transcript import itself never depends on its size.
        if data.count > sourceJSONTargetBytes, let canonical = sources.first {
            let remainingColumns = (canonical["columnNames"] as? [String])?.count ?? 0
            omittedColumns += remainingColumns
            omittedFields += remainingColumns
            var minimal: [String: Any] = [
                "name": canonical["name"] as? String ?? "unknown",
                "role": canonical["role"] as? String ?? "selected",
                "rowID": canonical["rowID"] as? Int64 ?? 0,
                "columnNames": [],
                "omittedColumnCount": omittedColumns,
            ]
            if let hash = canonical["omittedValuesSHA256"] as? String {
                minimal["omittedValuesSHA256"] = hash
            }
            sources = [minimal]
            data = try encode()
        }
        guard data.count <= WisprFlowImportLimits.maximumArtifactBytes else {
            throw WisprFlowSourceReaderError.sqlite("The bounded source archive could not be created.")
        }

        let recorded = Set(omissions.compactMap { entry -> String? in
            guard let raw = entry["artifact"] as? String,
                  let bytes = entry["observedByteCount"] as? Int,
                  let hash = entry["observedSHA256"] as? String else { return nil }
            return "\(raw):\(bytes):\(hash)"
        })
        let unarchived = originalUnarchived.filter {
            recorded.contains("\($0.filename.rawValue):\($0.byteCount):\($0.sha256)")
        }
        let warning: String? = omittedFields + omittedSources + omittedMediaVersions + omittedColumns > 0
            ? "Session \(sourceID.uuidString) has partial source provenance: \(omittedFields) field values summarized, \(omittedSources) older source rows omitted, and \(omittedMediaVersions) media version records omitted. source.json keeps available field details and aggregate omission digests."
            : nil
        return BoundedSourceJSON(data: data, unarchived: unarchived, warning: warning)
    }

    private static func typedValue(_ statement: OpaquePointer, column: Int32) -> [String: Any] {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL: return ["type": "null"]
        case SQLITE_INTEGER: return ["type": "integer", "value": sqlite3_column_int64(statement, column)]
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            return value.isFinite ? ["type": "real", "value": value]
                : ["type": "real", "value": String(value)]
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let pointer = sqlite3_column_text(statement, column) else { return ["type": "text", "value": ""] }
            let bytes = Data(bytes: pointer, count: count)
            if let value = String(data: bytes, encoding: .utf8) { return ["type": "text", "value": value] }
            return ["type": "text", "base64": bytes.base64EncodedString(), "encoding": "raw-bytes"]
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard let pointer = sqlite3_column_blob(statement, column) else { return ["type": "blob", "base64": ""] }
            return ["type": "blob", "base64": Data(bytes: pointer, count: count).base64EncodedString()]
        default: return ["type": "null"]
        }
    }

    private static func sqliteType(_ type: Int32) -> String {
        switch type {
        case SQLITE_INTEGER: "integer"
        case SQLITE_FLOAT: "real"
        case SQLITE_TEXT: "text"
        case SQLITE_BLOB: "blob"
        default: "null"
        }
    }

    private static func extract(column: String, rowID: Int64, from database: OpaquePointer, to url: URL) throws {
        var blob: OpaquePointer?
        let result = sqlite3_blob_open(database, "main", "History", column, rowID, 0, &blob)
        guard result == SQLITE_OK, let blob else {
            throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_blob_close(blob) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw WisprFlowSourceReaderError.cannotCreateArtifact(url)
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let size = Int(sqlite3_blob_bytes(blob))
        var offset = 0
        while offset < size {
            try Task.checkCancellation()
            let count = min(65_536, size - offset)
            var buffer = [UInt8](repeating: 0, count: count)
            let readResult = buffer.withUnsafeMutableBytes { bytes in
                sqlite3_blob_read(blob, bytes.baseAddress, Int32(count), Int32(offset))
            }
            guard readResult == SQLITE_OK else {
                throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            try output.write(contentsOf: Data(buffer))
            offset += count
        }
    }

    private static func hashBlob(column: String, rowID: Int64, from database: OpaquePointer) throws -> String {
        var blob: OpaquePointer?
        guard sqlite3_blob_open(database, "main", "History", column, rowID, 0, &blob) == SQLITE_OK,
              let blob else {
            throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_blob_close(blob) }
        var hasher = SHA256()
        let size = Int(sqlite3_blob_bytes(blob))
        var offset = 0
        while offset < size {
            try Task.checkCancellation()
            let count = min(65_536, size - offset)
            var buffer = [UInt8](repeating: 0, count: count)
            let result = buffer.withUnsafeMutableBytes { bytes in
                sqlite3_blob_read(blob, bytes.baseAddress, Int32(count), Int32(offset))
            }
            guard result == SQLITE_OK else {
                throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            hasher.update(data: Data(buffer))
            offset += count
        }
        try Task.checkCancellation()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidArtifact(_ url: URL, filename: String) throws -> Bool {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 12) ?? Data()
        switch filename {
        case "source.wav":
            return header.count >= 12 && header.prefix(4) == Data("RIFF".utf8)
                && header.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        case "screenshot.png":
            return header.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10])
        case "opus.json":
            let data = try Data(contentsOf: url)
            guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
            return object is [String: Any]
        default: return false
        }
    }

    private static func writeJSON(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WisprFlowSourceReaderError.sqlite("\(sql.prefix(80)): \(String(cString: sqlite3_errmsg(database)))")
        }
        return statement
    }

    private static func nextRow(_ statement: OpaquePointer, in database: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        default: throw WisprFlowSourceReaderError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        let bytes = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        return String(data: bytes, encoding: .utf8)
    }

    private static func number(_ statement: OpaquePointer, column: Int32) -> Double? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: sqlite3_column_double(statement, column)
        default: nil
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        if let date = formatter.date(from: value) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }
}
