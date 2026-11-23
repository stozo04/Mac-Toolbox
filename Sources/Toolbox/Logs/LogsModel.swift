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
    var status: LogStatus? { didSet { reload() } }
    var selectedID: Int64?

    /// The rows the filters select, newest first, at most `rowLimit`.
    private(set) var rows: [LogRow] = []
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

    var selected: LogRow? { rows.first { $0.id == selectedID } }
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
            // A status is worked out per event (it compares versions), so with one chosen every problem in the range
            // is read and filtered before the limit; otherwise an older match would hide behind newer events.
            let problemLevels = levels.filter { $0 >= .warning }
            let logs = try status == nil
                ? store.events(since: start, levels: levels, limit: Self.rowLimit + 1)
                : store.events(since: start, levels: problemLevels, limit: nil)
            let matching = logs.lazy.map { log in
                let resolution = resolutions[log.signature]
                return LogRow(log: log, status: LogStatus.of(log, resolution: resolution), resolution: resolution)
            }.filter { self.status == nil || $0.status == self.status }
            let all = Array(matching.prefix(Self.rowLimit + 1))
            rows = Array(all.prefix(Self.rowLimit))
            reachedLimit = all.count > Self.rowLimit
            counts = try store.counts(since: start)
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

    static let newIssuePage = URL(string: "https://github.com/stozo04/Mac-Toolbox/issues/new")
    /// GitHub refuses new-issue links much over 8 KB, so the details are cut until the whole encoded link fits.
    static let issueURLLimit = 7500
    static let issueFooter = "\n\n_From the Toolbox Logs page. The repository is public: check file names before submitting._"
    private static let issueCutNote = "\n…(cut to fit; the rest is in the Logs page)"
    /// Only these stay as they are in the link; everything else is percent-encoded, `+` included, which GitHub would
    /// otherwise read as a space.
    private static let plainQueryCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A new issue on the app's GitHub repository, filled in with this event, for the browser to open. Toolbox sends
    /// nothing itself: the issue exists only once it is submitted there.
    static func newIssueURL(for row: LogRow) -> URL? {
        let title = "\(row.event.category): \(row.event.message)"
        let details = markdown(row)
        guard let full = issueURL(title: title, body: details + issueFooter) else { return nil }
        if full.absoluteString.utf8.count <= issueURLLimit { return full }
        var shortest = 0, longest = details.count
        while shortest < longest {
            let middle = (shortest + longest + 1) / 2
            let candidate = issueURL(title: title, body: String(details.prefix(middle)) + issueCutNote + issueFooter)
            if let candidate, candidate.absoluteString.utf8.count <= issueURLLimit { shortest = middle } else { longest = middle - 1 }
        }
        return issueURL(title: title, body: String(details.prefix(shortest)) + issueCutNote + issueFooter)
    }

    private static func issueURL(title: String, body: String) -> URL? {
        guard let page = newIssuePage, var parts = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let title = title.addingPercentEncoding(withAllowedCharacters: plainQueryCharacters),
              let body = body.addingPercentEncoding(withAllowedCharacters: plainQueryCharacters) else { return nil }
        parts.percentEncodedQuery = "title=\(title)&body=\(body)"
        return parts.url
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
