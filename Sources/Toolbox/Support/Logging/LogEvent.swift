import Foundation

enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case info, warning, error, critical

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

struct LogEvent: Codable, Equatable, Sendable {
    var timestamp: Date
    var level: LogLevel
    /// Area of the app, e.g. "download" or "app".
    var category: String
    var message: String
    /// String facts about the event. File names, error text and links without a query string are welcome (see
    /// `Log.details`); never file contents, passwords, tokens or the account name.
    var metadata: [String: String]
    var appVersion: String
    var osVersion: String
    /// Random per install; not linked to any account.
    var installID: String
    /// Random per launch.
    var sessionID: String

    // Column names in the Supabase `mactoolkit_app_logs` table.
    enum CodingKeys: String, CodingKey {
        case timestamp, level, category, message, metadata
        case appVersion = "app_version", osVersion = "os_version"
        case installID = "install_id", sessionID = "session_id"
    }
}
