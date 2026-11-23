import Foundation

/// How far back the Logs page looks.
enum LogRange: String, CaseIterable, Identifiable, Sendable {
    case hour = "1 hr", fourHours = "4 hrs", twelveHours = "12 hrs", day = "1 day", twoDays = "2 days",
         threeDays = "3 days", fiveDays = "5 days", week = "Week", all = "All"

    var id: String { rawValue }

    private var hours: Double? {
        switch self {
        case .hour: 1
        case .fourHours: 4
        case .twelveHours: 12
        case .day: 24
        case .twoDays: 48
        case .threeDays: 72
        case .fiveDays: 120
        case .week: 168
        case .all: nil
        }
    }

    /// The oldest moment inside the range, or nil for every event kept.
    func start(now: Date) -> Date? { hours.map { now.addingTimeInterval(-$0 * 3600) } }
}

/// Where a warning, error or critical stands, from the log fixer's newest decision about its signature.
enum LogStatus: String, CaseIterable, Identifiable, Sendable {
    case open = "Open"
    case issueOpen = "Issue open"
    case fixProposed = "Fix proposed"
    case fixed = "Fixed"
    case cameBack = "Came back"
    case loggingImproved = "Logging improved"
    case watching = "Watching"
    case needsHuman = "Needs you"

    var id: String { rawValue }

    /// An issue, pull request or watch issue already follows this problem, so starting another issue would duplicate it.
    var alreadyTracked: Bool { self == .issueOpen || self == .fixProposed || self == .watching }

    /// Info events are a trail, not problems, so they have no status. A fix counts from the version it shipped in:
    /// the same problem from that version or a later one means the fix did not hold.
    static func of(_ log: StoredLog, resolution: LogResolution?) -> LogStatus? {
        guard log.event.level >= .warning else { return nil }
        guard let resolution else { return .open }
        switch resolution.outcome {
        case .issueOpen: return .issueOpen
        case .fixProposed: return .fixProposed
        case .watching: return .watching
        case .needsHuman: return .needsHuman
        case .fixed:
            return happened(log, atOrAfter: resolution.fixedInVersion) ? .cameBack : .fixed
        case .loggingImproved:
            return happened(log, atOrAfter: resolution.fixedInVersion) ? .open : .loggingImproved
        }
    }

    private static func happened(_ log: StoredLog, atOrAfter version: String?) -> Bool {
        guard let version, let shipped = VersionNumber(version), let seen = VersionNumber(log.event.appVersion) else { return false }
        return seen >= shipped
    }
}

/// A dotted version such as "0.12.10", compared number by number, so 0.12.10 is newer than 0.12.9.
struct VersionNumber: Comparable {
    let parts: [Int]

    init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    static func < (a: VersionNumber, b: VersionNumber) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (a: VersionNumber, b: VersionNumber) -> Bool { !(a < b) && !(b < a) }
}
