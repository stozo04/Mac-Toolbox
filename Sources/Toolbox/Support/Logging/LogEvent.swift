import Foundation

enum LogLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case info, warning, error, critical

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    static func < (a: LogLevel, b: LogLevel) -> Bool { a.rank < b.rank }
}

struct LogEvent: Equatable, Sendable {
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
}

extension LogEvent {
    /// What makes two events the same problem: `category | message | error_domain | error_code`, plus
    /// ` | program=<name>` when a program failed, so a `diskutil` timeout and an `ffmpeg` one stay apart.
    /// The log store saves it with every event, and the log fixer records its fixes against it.
    var signature: String {
        var parts = [category, message, metadata["error_domain"] ?? "", metadata["error_code"] ?? ""]
        if let program = metadata["program"] { parts.append("program=\(program)") }
        return parts.joined(separator: " | ")
    }

    /// "v0.12.4" for a released version, "dev" for a run from the project.
    var versionLabel: String { VersionNumber(appVersion) == nil ? appVersion : "v\(appVersion)" }
}
