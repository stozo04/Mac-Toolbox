import Foundation
import SQLite3

/// One SQLite connection with the few calls Toolbox needs. The owner makes the errors, so each store keeps the error
/// type its callers and its logs already know (a log signature includes the error's domain).
final class SQLiteDatabase {
    typealias Statement = OpaquePointer

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer?
    private let makeError: (String) -> Error

    init(at url: URL, makeError: @escaping (String) -> Error) throws {
        self.makeError = makeError
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            db = nil
            throw makeError(message)
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// For a file another process writes too: readers never block the writer, and a busy file is retried, not failed.
    func shareWithOtherProcesses(busyTimeoutMilliseconds: Int32 = 5000) throws {
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        try execute("PRAGMA journal_mode=WAL")
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func run(_ sql: String, bind: (Statement) -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    func query(_ sql: String, bind: (Statement) -> Void = { _ in }, row: (Statement) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw error() }
            row(statement)
        }
    }

    func inTransaction(_ changes: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try changes()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func error() -> Error {
        makeError(db.map { String(cString: sqlite3_errmsg($0)) } ?? "the database is closed")
    }

    // MARK: Values

    static func bind(_ statement: Statement, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    static func bind(_ statement: Statement, _ index: Int32, _ text: String?) {
        if let text { bind(statement, index, text) } else { sqlite3_bind_null(statement, index) }
    }

    static func bind(_ statement: Statement, _ index: Int32, bytes: UnsafeRawBufferPointer) {
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
    }

    static func text(_ statement: Statement, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    static func optionalText(_ statement: Statement, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }
}
