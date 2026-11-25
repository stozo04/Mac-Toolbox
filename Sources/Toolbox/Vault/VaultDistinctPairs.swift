import Foundation
import SQLite3

struct VaultDuplicatesStoreError: LocalizedError {
    let reason: String
    var errorDescription: String? { "The vault's duplicates file failed: \(reason)" }
}

/// What the vault remembers about duplicates, in `.toolbox/duplicates.sqlite` inside the encrypted image: the sets
/// kept whole on purpose, so they are never suggested again, and the downloads to compare the next time the vault opens.
/// Files are known by their SHA-256, so a rename or a move keeps what was decided.
final class VaultDistinctPairs {
    static let fileName = "duplicates.sqlite"

    private let database: SQLiteDatabase
    private(set) var keptTogether: Set<Key>

    struct Key: Hashable {
        let first: String
        let second: String

        init(_ a: Data, _ b: Data) {
            let hexes = [a.hexString, b.hexString].sorted()
            first = hexes[0]
            second = hexes[1]
        }

        fileprivate init(first: String, second: String) {
            self.first = first
            self.second = second
        }
    }

    struct PendingReview: Equatable {
        let digest: Data
        let path: String
    }

    init(privateFolder: URL) throws {
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        database = try SQLiteDatabase(at: privateFolder.appendingPathComponent(Self.fileName)) { VaultDuplicatesStoreError(reason: $0) }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS distinct_pairs(first TEXT NOT NULL, second TEXT NOT NULL, decided REAL NOT NULL,
                                                      PRIMARY KEY(first, second));
            CREATE TABLE IF NOT EXISTS pending_reviews(digest TEXT PRIMARY KEY, path TEXT NOT NULL, queued REAL NOT NULL);
            """)
        var found = Set<Key>()
        try database.query("SELECT first, second FROM distinct_pairs") { row in
            found.insert(Key(first: SQLiteDatabase.text(row, 0), second: SQLiteDatabase.text(row, 1)))
        }
        keptTogether = found
    }

    func close() { database.close() }

    func isKeptTogether(_ a: Data, _ b: Data) -> Bool {
        keptTogether.contains(Key(a, b))
    }

    /// Every pair among `digests` is remembered, so a set kept whole is never suggested again.
    func keepTogether(_ digests: [Data]) throws {
        let keys = digests.indices.flatMap { i in digests[(i + 1)...].map { Key(digests[i], $0) } }
        let now = Date().timeIntervalSince1970
        try database.inTransaction {
            for key in keys {
                try database.run("INSERT OR IGNORE INTO distinct_pairs(first, second, decided) VALUES (?, ?, ?)") { statement in
                    SQLiteDatabase.bind(statement, 1, key.first)
                    SQLiteDatabase.bind(statement, 2, key.second)
                    sqlite3_bind_double(statement, 3, now)
                }
            }
        }
        keptTogether.formUnion(keys)
    }

    func queueReview(digest: Data, path: String) throws {
        try database.run("INSERT OR REPLACE INTO pending_reviews(digest, path, queued) VALUES (?, ?, ?)") { statement in
            SQLiteDatabase.bind(statement, 1, digest.hexString)
            SQLiteDatabase.bind(statement, 2, path)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        }
    }

    func pendingReviews() throws -> [PendingReview] {
        var found: [PendingReview] = []
        try database.query("SELECT digest, path FROM pending_reviews ORDER BY queued") { row in
            guard let digest = Data(hexString: SQLiteDatabase.text(row, 0)) else { return }
            found.append(PendingReview(digest: digest, path: SQLiteDatabase.text(row, 1)))
        }
        return found
    }

    func finishReviews(_ digests: [Data]) throws {
        try database.inTransaction {
            for digest in digests {
                try database.run("DELETE FROM pending_reviews WHERE digest = ?") { SQLiteDatabase.bind($0, 1, digest.hexString) }
            }
        }
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
