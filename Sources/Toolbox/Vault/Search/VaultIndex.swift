import Foundation
import SQLite3
import VaultSearch

struct VaultSegment: Equatable {
    let modality: Modality
    let start: Double
    let end: Double
    let vector: [Float]
}

struct VaultIndexedFile: Equatable {
    let bytes: Int64
    let modified: Double
}

struct VaultVectors {
    var paths: [String] = []
    var modalities: [Modality] = []
    var starts: [Double] = []
    var matrix: [Float] = []

    var rows: Int { paths.count }
}

enum VaultIndexError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): "The search index failed: \(message)"
        }
    }
}

final class VaultIndex {
    static let fileName = "index.sqlite"
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var db: OpaquePointer?

    init(at url: URL, vectorSource: String = LlamaEmbedder.vectorSource) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw VaultIndexError.sqlite(message)
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, bytes INTEGER, modified REAL);
            CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY, path TEXT, modality TEXT, start REAL, finish REAL, vector BLOB);
            CREATE INDEX IF NOT EXISTS segments_path ON segments(path);
            """)
        if meta("vector_source") != vectorSource {
            try execute("DELETE FROM segments; DELETE FROM files;")
            try setMeta("vector_source", vectorSource)
        }
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func files() throws -> [String: VaultIndexedFile] {
        var out: [String: VaultIndexedFile] = [:]
        try query("SELECT path, bytes, modified FROM files") { statement in
            out[Self.text(statement, 0)] = VaultIndexedFile(bytes: sqlite3_column_int64(statement, 1), modified: sqlite3_column_double(statement, 2))
        }
        return out
    }

    func store(path: String, file: VaultIndexedFile, segments: [VaultSegment]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM segments WHERE path = ?") { Self.bind($0, 1, path) }
            for segment in segments {
                try run("INSERT INTO segments(path, modality, start, finish, vector) VALUES(?, ?, ?, ?, ?)") { statement in
                    Self.bind(statement, 1, path)
                    Self.bind(statement, 2, segment.modality.rawValue)
                    sqlite3_bind_double(statement, 3, segment.start)
                    sqlite3_bind_double(statement, 4, segment.end)
                    segment.vector.withUnsafeBytes { _ = sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), Self.transient) }
                }
            }
            try run("INSERT OR REPLACE INTO files(path, bytes, modified) VALUES(?, ?, ?)") { statement in
                Self.bind(statement, 1, path)
                sqlite3_bind_int64(statement, 2, file.bytes)
                sqlite3_bind_double(statement, 3, file.modified)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func remove(_ paths: [String]) throws {
        for path in paths {
            try run("DELETE FROM segments WHERE path = ?") { Self.bind($0, 1, path) }
            try run("DELETE FROM files WHERE path = ?") { Self.bind($0, 1, path) }
        }
    }

    func vectors(dimension: Int = LlamaEmbedder.dimension) throws -> VaultVectors {
        var out = VaultVectors()
        try query("SELECT path, modality, start, vector FROM segments ORDER BY id") { statement in
            let bytes = Int(sqlite3_column_bytes(statement, 3))
            guard bytes == dimension * MemoryLayout<Float>.size, let blob = sqlite3_column_blob(statement, 3),
                  let modality = Modality(rawValue: Self.text(statement, 1)) else { return }
            out.paths.append(Self.text(statement, 0))
            out.modalities.append(modality)
            out.starts.append(sqlite3_column_double(statement, 2))
            out.matrix.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
        }
        return out
    }

    func meta(_ key: String) -> String? {
        var value: String?
        try? query("SELECT value FROM meta WHERE key = ?", bind: { Self.bind($0, 1, key) }) { value = Self.text($0, 0) }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)") { statement in
            Self.bind(statement, 1, key)
            Self.bind(statement, 2, value)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> Void) throws {
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

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return statement
    }

    private func error() -> VaultIndexError {
        VaultIndexError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "the index is closed")
    }

    private static func bind(_ statement: OpaquePointer, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, transient)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
