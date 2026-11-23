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

struct VaultIndexCoverage: Equatable {
    let file: VaultIndexedFile
    let segments: [Modality: Int]
}

struct VaultVectors {
    var paths: [String] = []
    var modalities: [Modality] = []
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
    private let db: SQLiteDatabase

    init(at url: URL, vectorSource: String = LlamaEmbedder.vectorSource) throws {
        db = try SQLiteDatabase(at: url) { VaultIndexError.sqlite($0) }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, bytes INTEGER, modified REAL);
            CREATE TABLE IF NOT EXISTS segments(id INTEGER PRIMARY KEY, path TEXT, modality TEXT, start REAL, finish REAL, vector BLOB);
            CREATE INDEX IF NOT EXISTS segments_path ON segments(path);
            """)
        if meta("vector_source") != vectorSource {
            try db.execute("DELETE FROM segments; DELETE FROM files;")
            try setMeta("vector_source", vectorSource)
        }
    }

    func close() { db.close() }

    func files() throws -> [String: VaultIndexedFile] {
        var out: [String: VaultIndexedFile] = [:]
        try db.query("SELECT path, bytes, modified FROM files") { statement in
            out[SQLiteDatabase.text(statement, 0)] = VaultIndexedFile(bytes: sqlite3_column_int64(statement, 1), modified: sqlite3_column_double(statement, 2))
        }
        return out
    }

    func store(path: String, file: VaultIndexedFile, segments: [VaultSegment]) throws {
        try db.inTransaction {
            try db.run("DELETE FROM segments WHERE path = ?") { SQLiteDatabase.bind($0, 1, path) }
            for segment in segments {
                try db.run("INSERT INTO segments(path, modality, start, finish, vector) VALUES(?, ?, ?, ?, ?)") { statement in
                    SQLiteDatabase.bind(statement, 1, path)
                    SQLiteDatabase.bind(statement, 2, segment.modality.rawValue)
                    sqlite3_bind_double(statement, 3, segment.start)
                    sqlite3_bind_double(statement, 4, segment.end)
                    segment.vector.withUnsafeBytes { SQLiteDatabase.bind(statement, 5, bytes: $0) }
                }
            }
            try db.run("INSERT OR REPLACE INTO files(path, bytes, modified) VALUES(?, ?, ?)") { statement in
                SQLiteDatabase.bind(statement, 1, path)
                sqlite3_bind_int64(statement, 2, file.bytes)
                sqlite3_bind_double(statement, 3, file.modified)
            }
        }
    }

    func remove(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try db.inTransaction {
            for path in paths {
                try db.run("DELETE FROM segments WHERE path = ?") { SQLiteDatabase.bind($0, 1, path) }
                try db.run("DELETE FROM files WHERE path = ?") { SQLiteDatabase.bind($0, 1, path) }
            }
        }
    }

    func rename(_ oldPath: String, to newPath: String) throws {
        try db.inTransaction {
            try db.run("DELETE FROM segments WHERE path = ?") { SQLiteDatabase.bind($0, 1, newPath) }
            try db.run("DELETE FROM files WHERE path = ?") { SQLiteDatabase.bind($0, 1, newPath) }
            for table in ["segments", "files"] {
                try db.run("UPDATE \(table) SET path = ? WHERE path = ?") { statement in
                    SQLiteDatabase.bind(statement, 1, newPath)
                    SQLiteDatabase.bind(statement, 2, oldPath)
                }
            }
        }
    }

    func coverage(of path: String) throws -> VaultIndexCoverage? {
        var file: VaultIndexedFile?
        try db.query("SELECT bytes, modified FROM files WHERE path = ?", bind: { SQLiteDatabase.bind($0, 1, path) }) { statement in
            file = VaultIndexedFile(bytes: sqlite3_column_int64(statement, 0), modified: sqlite3_column_double(statement, 1))
        }
        guard let file else { return nil }
        var counts: [Modality: Int] = [:]
        try db.query("SELECT modality, COUNT(*) FROM segments WHERE path = ? GROUP BY modality", bind: { SQLiteDatabase.bind($0, 1, path) }) { statement in
            if let modality = Modality(rawValue: SQLiteDatabase.text(statement, 0)) { counts[modality] = Int(sqlite3_column_int(statement, 1)) }
        }
        return VaultIndexCoverage(file: file, segments: counts)
    }

    func vectors(dimension: Int = LlamaEmbedder.dimension) throws -> VaultVectors {
        var out = VaultVectors()
        try db.query("SELECT path, modality, vector FROM segments ORDER BY id") { statement in
            let bytes = Int(sqlite3_column_bytes(statement, 2))
            guard bytes == dimension * MemoryLayout<Float>.size, let blob = sqlite3_column_blob(statement, 2),
                  let modality = Modality(rawValue: SQLiteDatabase.text(statement, 1)) else { return }
            out.paths.append(SQLiteDatabase.text(statement, 0))
            out.modalities.append(modality)
            out.matrix.append(contentsOf: UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: dimension))
        }
        return out
    }

    func pathsWithSound() throws -> Set<String> {
        var paths: Set<String> = []
        try db.query("SELECT DISTINCT path FROM segments WHERE modality = 'audio'") { statement in
            paths.insert(SQLiteDatabase.text(statement, 0))
        }
        return paths
    }

    func meta(_ key: String) -> String? {
        var value: String?
        try? db.query("SELECT value FROM meta WHERE key = ?", bind: { SQLiteDatabase.bind($0, 1, key) }) { value = SQLiteDatabase.text($0, 0) }
        return value
    }

    func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)") { statement in
            SQLiteDatabase.bind(statement, 1, key)
            SQLiteDatabase.bind(statement, 2, value)
        }
    }
}
