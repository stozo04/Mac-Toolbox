import Foundation
import SQLite3

enum LogStoreError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "The log store failed: \(message)"
        }
    }
}

/// An event as it was saved, with the row id the Logs page selects it by.
struct StoredLog: Identifiable, Equatable, Sendable {
    let id: Int64
    let event: LogEvent
    let signature: String
}

/// What the log fixer did about one signature. Kept as a history: a later decision is a new row, and the newest wins.
struct LogResolution: Equatable, Sendable {
    enum Outcome: String, CaseIterable, Sendable {
        case fixProposed = "fix_proposed"
        case fixed
        case loggingImproved = "logging_improved"
        case watching
        case needsHuman = "needs_human"
    }

    var signature: String
    var outcome: Outcome
    /// GitHub pull requests or issues, in the order the log fixer wrote them.
    var links: [URL]
    var note: String
    var decidedAt: Date
    /// The app version the fix (or the better logging) first shipped in; set once its pull request is merged.
    var fixedInVersion: String?
}

/// The app's own log: every event, in `logs.sqlite` on this Mac. The installed app writes it, the Logs page reads it,
/// and the log fixer reads the events and writes `log_resolutions` with the `sqlite3` tool. This type owns the schema.
///
/// One connection may be used from several threads: it is opened in SQLite's serialized mode.
final class LogStore: @unchecked Sendable {
    static let fileName = "logs.sqlite"
    static let keepFor: TimeInterval = 90 * 24 * 3600

    private let db: SQLiteDatabase
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDatabase(at: url) { LogStoreError.sqlite($0) }
        try db.shareWithOtherProcesses()
        try db.execute("""
            CREATE TABLE IF NOT EXISTS logs(
                id INTEGER PRIMARY KEY,
                timestamp REAL NOT NULL,
                level TEXT NOT NULL CHECK(level IN ('info', 'warning', 'error', 'critical')),
                category TEXT NOT NULL,
                message TEXT NOT NULL,
                metadata TEXT NOT NULL DEFAULT '{}',
                app_version TEXT NOT NULL,
                os_version TEXT NOT NULL,
                install_id TEXT NOT NULL,
                session_id TEXT NOT NULL,
                signature TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS logs_timestamp ON logs(timestamp);
            CREATE INDEX IF NOT EXISTS logs_signature ON logs(signature);
            CREATE TABLE IF NOT EXISTS log_resolutions(
                id INTEGER PRIMARY KEY,
                signature TEXT NOT NULL,
                outcome TEXT NOT NULL CHECK(outcome IN (\(Self.outcomeList))),
                links TEXT NOT NULL DEFAULT '',
                note TEXT NOT NULL DEFAULT '',
                decided_at REAL NOT NULL,
                fixed_in_version TEXT);
            CREATE INDEX IF NOT EXISTS log_resolutions_signature ON log_resolutions(signature);
            """)
    }

    private static var outcomeList: String {
        LogResolution.Outcome.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    }

    // MARK: Events

    func append(_ event: LogEvent) throws {
        let metadata = String(bytes: try encoder.encode(event.metadata), encoding: .utf8) ?? "{}"
        try db.run("""
            INSERT INTO logs(timestamp, level, category, message, metadata, app_version, os_version, install_id, session_id, signature)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
            let texts = [event.level.rawValue, event.category, event.message, metadata, event.appVersion, event.osVersion,
                         event.installID, event.sessionID, event.signature]
            for (offset, text) in texts.enumerated() { SQLiteDatabase.bind(statement, Int32(offset + 2), text) }
        }
    }

    func deleteEvents(olderThan date: Date) throws {
        try db.run("DELETE FROM logs WHERE timestamp < ?") { sqlite3_bind_double($0, 1, date.timeIntervalSince1970) }
    }

    /// Newest first. `since` nil means every event kept; `limit` nil means no limit.
    func events(since: Date?, levels: Set<LogLevel>, limit: Int?) throws -> [StoredLog] {
        guard !levels.isEmpty else { return [] }
        let chosen = LogLevel.allCases.filter(levels.contains)
        let placeholders = Array(repeating: "?", count: chosen.count).joined(separator: ", ")
        var out: [StoredLog] = []
        try db.query("""
            SELECT id, timestamp, level, category, message, metadata, app_version, os_version, install_id, session_id, signature
            FROM logs WHERE timestamp >= ? AND level IN (\(placeholders)) ORDER BY timestamp DESC, id DESC LIMIT ?
            """, bind: { statement in
            sqlite3_bind_double(statement, 1, since?.timeIntervalSince1970 ?? 0)
            for (offset, level) in chosen.enumerated() { SQLiteDatabase.bind(statement, Int32(offset + 2), level.rawValue) }
            sqlite3_bind_int64(statement, Int32(chosen.count + 2), limit.map(Int64.init) ?? -1)
        }) { statement in
            if let log = Self.storedLog(statement) { out.append(log) }
        }
        return out
    }

    func counts(since: Date?) throws -> [LogLevel: Int] {
        var out: [LogLevel: Int] = [:]
        try db.query("SELECT level, COUNT(*) FROM logs WHERE timestamp >= ? GROUP BY level", bind: {
            sqlite3_bind_double($0, 1, since?.timeIntervalSince1970 ?? 0)
        }) { statement in
            if let level = LogLevel(rawValue: SQLiteDatabase.text(statement, 0)) { out[level] = Int(sqlite3_column_int64(statement, 1)) }
        }
        return out
    }

    private static func storedLog(_ statement: SQLiteDatabase.Statement) -> StoredLog? {
        guard let level = LogLevel(rawValue: SQLiteDatabase.text(statement, 2)) else { return nil }
        let metadataJSON = Data(SQLiteDatabase.text(statement, 5).utf8)
        let metadata = (try? JSONDecoder().decode([String: String].self, from: metadataJSON)) ?? [:]
        let event = LogEvent(timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), level: level,
                             category: SQLiteDatabase.text(statement, 3), message: SQLiteDatabase.text(statement, 4),
                             metadata: metadata, appVersion: SQLiteDatabase.text(statement, 6),
                             osVersion: SQLiteDatabase.text(statement, 7), installID: SQLiteDatabase.text(statement, 8),
                             sessionID: SQLiteDatabase.text(statement, 9))
        return StoredLog(id: sqlite3_column_int64(statement, 0), event: event, signature: SQLiteDatabase.text(statement, 10))
    }

    // MARK: Resolutions

    func record(_ resolution: LogResolution) throws {
        try db.run("""
            INSERT INTO log_resolutions(signature, outcome, links, note, decided_at, fixed_in_version) VALUES(?, ?, ?, ?, ?, ?)
            """) { statement in
            SQLiteDatabase.bind(statement, 1, resolution.signature)
            SQLiteDatabase.bind(statement, 2, resolution.outcome.rawValue)
            SQLiteDatabase.bind(statement, 3, resolution.links.map(\.absoluteString).joined(separator: " "))
            SQLiteDatabase.bind(statement, 4, resolution.note)
            sqlite3_bind_double(statement, 5, resolution.decidedAt.timeIntervalSince1970)
            SQLiteDatabase.bind(statement, 6, resolution.fixedInVersion)
        }
    }

    /// The newest decision for every signature that has one.
    func latestResolutions() throws -> [String: LogResolution] {
        var out: [String: LogResolution] = [:]
        try db.query("""
            SELECT signature, outcome, links, note, decided_at, fixed_in_version FROM log_resolutions AS r
            WHERE id = (SELECT MAX(id) FROM log_resolutions WHERE signature = r.signature)
            """) { statement in
            guard let outcome = LogResolution.Outcome(rawValue: SQLiteDatabase.text(statement, 1)) else { return }
            let signature = SQLiteDatabase.text(statement, 0)
            out[signature] = LogResolution(signature: signature, outcome: outcome,
                                           links: Self.gitHubLinks(SQLiteDatabase.text(statement, 2)),
                                           note: SQLiteDatabase.text(statement, 3),
                                           decidedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                                           fixedInVersion: SQLiteDatabase.optionalText(statement, 5))
        }
        return out
    }

    /// Only https links to github.com are kept: the page opens them in the browser, and the table is written by a tool.
    static func gitHubLinks(_ text: String) -> [URL] {
        text.split(whereSeparator: \.isWhitespace).compactMap { URL(string: String($0)) }
            .filter { $0.scheme == "https" && $0.host == "github.com" }
    }
}
