import Foundation
import SQLite3

struct VaultDuplicatesStoreError: LocalizedError {
    let reason: String
    var errorDescription: String? { "The vault's duplicates file failed: \(reason)" }
}

/// What the vault remembers about duplicates, in `.toolbox/duplicates.sqlite` inside the encrypted image: the sets
/// kept whole on purpose, so they are never suggested again, and the downloads to compare the next time the vault opens.
/// Files are known by their SHA-256, so a rename or a move keeps what was decided. Byte-identical copies share one
/// digest, so for them the store keeps how many were kept: one more copy of the same bytes is suggested again.
final class VaultDistinctPairs {
    static let fileName = "duplicates.sqlite"

    private let database: SQLiteDatabase
    private(set) var remembered: Remembered

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

    /// What was kept whole, as a value the matcher can take off the main actor.
    struct Remembered: Equatable, Sendable {
        var pairs: Set<Key> = []
        /// Digest in hex → how many identical copies were kept together.
        var copies: [String: Int] = [:]

        var isEmpty: Bool { pairs.isEmpty && copies.isEmpty }

        /// `count` is how many files with `a`'s bytes are being compared now.
        func hides(_ a: Data, _ b: Data, count: Int) -> Bool {
            guard a == b else { return pairs.contains(Key(a, b)) }
            return (copies[a.hexString] ?? 0) >= count
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
            CREATE TABLE IF NOT EXISTS kept_copies(digest TEXT PRIMARY KEY, copies INTEGER NOT NULL, decided REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS pending_reviews(path TEXT PRIMARY KEY, digest TEXT NOT NULL, queued REAL NOT NULL);
            """)
        var found = Remembered()
        try database.query("SELECT first, second FROM distinct_pairs") { row in
            found.pairs.insert(Key(first: SQLiteDatabase.text(row, 0), second: SQLiteDatabase.text(row, 1)))
        }
        try database.query("SELECT digest, copies FROM kept_copies") { row in
            found.copies[SQLiteDatabase.text(row, 0)] = Int(sqlite3_column_int64(row, 1))
        }
        remembered = found
    }

    func close() { database.close() }

    /// Remembers a set kept whole: every pair of different files, and for identical files how many were kept.
    func keepTogether(_ digests: [Data]) throws {
        let keys = Set(digests.indices.flatMap { i in digests[(i + 1)...].map { (digests[i], $0) } }
            .filter { $0.0 != $0.1 }.map { Key($0.0, $0.1) })
        let counts = Dictionary(grouping: digests.map(\.hexString), by: { $0 }).mapValues(\.count).filter { $0.value > 1 }
        let now = Date().timeIntervalSince1970
        try database.inTransaction {
            for key in keys {
                try database.run("INSERT OR IGNORE INTO distinct_pairs(first, second, decided) VALUES (?, ?, ?)") { statement in
                    SQLiteDatabase.bind(statement, 1, key.first)
                    SQLiteDatabase.bind(statement, 2, key.second)
                    sqlite3_bind_double(statement, 3, now)
                }
            }
            for (digest, copies) in counts {
                try database.run("""
                    INSERT INTO kept_copies(digest, copies, decided) VALUES (?, ?, ?)
                    ON CONFLICT(digest) DO UPDATE SET copies = max(copies, excluded.copies), decided = excluded.decided
                    """) { statement in
                    SQLiteDatabase.bind(statement, 1, digest)
                    sqlite3_bind_int64(statement, 2, Int64(copies))
                    sqlite3_bind_double(statement, 3, now)
                }
            }
        }
        remembered.pairs.formUnion(keys)
        remembered.copies.merge(counts) { max($0, $1) }
    }

    func queueReview(digest: Data, path: String) throws {
        try database.run("INSERT OR REPLACE INTO pending_reviews(digest, path, queued) VALUES (?, ?, ?)") { statement in
            SQLiteDatabase.bind(statement, 1, digest.hexString)
            SQLiteDatabase.bind(statement, 2, path)
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        }
    }

    /// A queued download that was renamed is still compared the next time the vault opens.
    func movePendingReview(from oldPath: String, to newPath: String) throws {
        try database.run("UPDATE pending_reviews SET path = ? WHERE path = ?") { statement in
            SQLiteDatabase.bind(statement, 1, newPath)
            SQLiteDatabase.bind(statement, 2, oldPath)
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
