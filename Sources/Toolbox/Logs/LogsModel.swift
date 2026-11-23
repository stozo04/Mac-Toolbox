import AppKit
import Foundation
import Observation

struct LogRow: Identifiable, Equatable {
    let log: StoredLog
    let status: LogStatus?
    let resolution: LogResolution?

    var id: Int64 { log.id }
    var event: LogEvent { log.event }
}

/// The Logs page's state: the chosen range, levels and status, the rows they select and the count of each level.
@MainActor @Observable
final class LogsModel {
    /// The page shows at most this many of the newest matching events; the counts always cover the whole range.
    static let rowLimit = 2000

    var range: LogRange = .all { didSet { reload() } }
    private(set) var levels: Set<LogLevel> = Set(LogLevel.allCases)
    /// nil shows every status; a status hides info events, which have none.
    var status: LogStatus?
    var selectedID: Int64?

    private(set) var allRows: [LogRow] = []
    private(set) var counts: [LogLevel: Int] = [:]
    private(set) var reachedLimit = false
    private(set) var problem: String?

    private let store: LogStore?
    private let now: () -> Date

    init(store: LogStore?, problem: String? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.problem = problem
        self.now = now
    }

    static func forLaunch() -> LogsModel {
        do {
            return LogsModel(store: try LogStore(at: LogStoreLocation.launch()))
        } catch {
            return LogsModel(store: nil, problem: error.localizedDescription)
        }
    }

    var rows: [LogRow] {
        guard let status else { return allRows }
        return allRows.filter { $0.status == status }
    }

    var selected: LogRow? { allRows.first { $0.id == selectedID } }
    var showsEveryLevel: Bool { levels.count == LogLevel.allCases.count }
    var totalInRange: Int { counts.values.reduce(0, +) }

    /// From every level, the first click narrows to that one; after that each click adds or removes a level,
    /// and taking away the last one shows every level again.
    func toggle(_ level: LogLevel) {
        if showsEveryLevel {
            levels = [level]
        } else if levels.contains(level) {
            levels.remove(level)
            if levels.isEmpty { levels = Set(LogLevel.allCases) }
        } else {
            levels.insert(level)
        }
        reload()
    }

    func showEveryLevel() {
        levels = Set(LogLevel.allCases)
        reload()
    }

    func reload() {
        guard let store else { return }
        do {
            let start = range.start(now: now())
            let resolutions = try store.latestResolutions()
            let logs = try store.events(since: start, levels: levels, limit: Self.rowLimit)
            allRows = logs.map { log in
                let resolution = resolutions[log.signature]
                return LogRow(log: log, status: LogStatus.of(log, resolution: resolution), resolution: resolution)
            }
            counts = try store.counts(since: start)
            reachedLimit = logs.count == Self.rowLimit
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func copyMarkdown(of row: LogRow, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(Self.markdown(row), forType: .string)
    }

    static func markdown(_ row: LogRow) -> String {
        let event = row.event
        var lines = [
            "**\(event.level.rawValue)** · \(event.category) · \(utcStamp(event.timestamp)) · \(event.versionLabel) · \(event.osVersion)",
            "",
            "> \(event.message)",
            "",
            "Signature: `\(row.log.signature)`",
        ]
        if let status = row.status { lines.append("Status: \(statusLine(status, row.resolution))") }
        if let note = row.resolution?.note, !note.isEmpty { lines.append("Log fixer: \(note)") }
        if !event.metadata.isEmpty {
            lines += ["", "```"] + event.metadata.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" } + ["```"]
        }
        return lines.joined(separator: "\n")
    }

    static func statusLine(_ status: LogStatus, _ resolution: LogResolution?) -> String {
        var parts = [status.rawValue]
        if let version = resolution?.fixedInVersion, status == .fixed || status == .cameBack || status == .loggingImproved {
            parts.append("in v\(version)")
        }
        let links = resolution?.links ?? []
        if !links.isEmpty { parts.append("(" + links.map(\.absoluteString).joined(separator: ", ") + ")") }
        return parts.joined(separator: " ")
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func utcStamp(_ date: Date) -> String { utcFormatter.string(from: date) + " UTC" }
}
