import Foundation
import os

/// Where log events go. Implement this to add a destination (console, Supabase, a file...).
protocol LogSink: Sendable {
    /// Events below this level are not sent to the sink.
    var minimumLevel: LogLevel { get }
    func write(_ event: LogEvent)
}

/// App-wide logger. Call `Log.info(...)` anywhere; sinks are chosen once at launch.
///
///     Log.error("Download failed", category: "download", ["host": "youtube.com"])
enum Log {
    private static let state = LockedState()

    static func configure(sinks: [LogSink]) { state.sinks = sinks }

    static func info(_ message: String, category: String = "app", _ metadata: [String: String] = [:]) {
        write(.info, message, category, metadata)
    }
    static func warning(_ message: String, category: String = "app", _ metadata: [String: String] = [:]) {
        write(.warning, message, category, metadata)
    }
    static func error(_ message: String, category: String = "app", _ metadata: [String: String] = [:]) {
        write(.error, message, category, metadata)
    }
    static func critical(_ message: String, category: String = "app", _ metadata: [String: String] = [:]) {
        write(.critical, message, category, metadata)
    }

    static func write(_ level: LogLevel, _ message: String, _ category: String, _ metadata: [String: String]) {
        var metadata = metadata
        // Failures carry where the user was and the last few things that happened, so they can be understood alone.
        if level >= .warning { metadata.merge(state.context()) { mine, _ in mine } }
        let event = LogEvent(timestamp: Date(), level: level, category: category, message: message,
                             metadata: metadata, appVersion: AppInfo.version, osVersion: AppInfo.osVersion,
                             installID: AppInfo.installID, sessionID: AppInfo.sessionID).fitted()
        state.remember(event)
        for sink in state.sinks where level >= sink.minimumLevel { sink.write(event) }
    }

    /// Call when the user moves to another page, e.g. "Video/Trim Video".
    static func navigate(to page: String) {
        state.page = page
        info("Opened page", category: "nav", ["page": page])
    }

    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var _sinks: [LogSink] = []
        private var _page = "home"
        private var crumbs: [(time: Date, text: String)] = []
        private let maxCrumbs = 10

        var sinks: [LogSink] {
            get { lock.lock(); defer { lock.unlock() }; return _sinks }
            set { lock.lock(); _sinks = newValue; lock.unlock() }
        }
        var page: String {
            get { lock.lock(); defer { lock.unlock() }; return _page }
            set { lock.lock(); _page = newValue; lock.unlock() }
        }

        func remember(_ event: LogEvent) {
            lock.lock(); defer { lock.unlock() }
            crumbs.append((event.timestamp, "[\(event.category)] \(event.message)"))
            if crumbs.count > maxCrumbs { crumbs.removeFirst(crumbs.count - maxCrumbs) }
        }

        /// `page` plus the latest events, oldest first, e.g. "-12s [nav] Opened page | -3s [convert-images] Image converted".
        func context() -> [String: String] {
            lock.lock(); defer { lock.unlock() }
            var m = ["page": _page]
            let now = Date()
            let recent = crumbs.map { "-\(Int(now.timeIntervalSince($0.time)))s \(LogText.clean($0.text, limit: 80))" }
            if !recent.isEmpty { m["recent"] = recent.joined(separator: " | ") }
            return m
        }
    }
}

enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let sessionID = UUID().uuidString

    /// True for anything built or run from the project (`swift run`, a debug build, `.build/`), as opposed to the
    /// installed app. Those runs are full of half-finished experiments, so they must not reach the shared log table.
    static let isDevelopmentRun: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.bundlePath.contains("/.build/")
        #endif
    }()

    /// Whether this run may send events to Supabase. `TOOLBOX_LOG_REMOTE=1` forces it on, to test the pipeline.
    static func sendsRemoteLogs(environment: [String: String] = ProcessInfo.processInfo.environment,
                                isDevelopmentRun: Bool = AppInfo.isDevelopmentRun) -> Bool {
        environment["TOOLBOX_LOG_REMOTE"] == "1" || !isDevelopmentRun
    }

    static let installID: String = {
        let key = "toolbox.installID"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
}

/// Prints to Xcode / Console.app through the unified logging system.
struct ConsoleLogSink: LogSink {
    var minimumLevel: LogLevel = .info
    private let logger = os.Logger(subsystem: "com.toolbox.app", category: "app")

    func write(_ e: LogEvent) {
        let meta = e.metadata.isEmpty ? "" : " " + e.metadata.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: " ")
        let line = "[\(e.category)] \(e.message)\(meta)"
        switch e.level {
        case .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        case .critical: logger.critical("\(line, privacy: .public)")
        }
    }
}
