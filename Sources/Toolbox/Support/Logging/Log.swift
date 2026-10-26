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
        let event = LogEvent(timestamp: Date(), level: level, category: category, message: message,
                             metadata: metadata, appVersion: AppInfo.version, osVersion: AppInfo.osVersion,
                             installID: AppInfo.installID, sessionID: AppInfo.sessionID)
        for sink in state.sinks where level >= sink.minimumLevel { sink.write(event) }
    }

    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var _sinks: [LogSink] = []
        var sinks: [LogSink] {
            get { lock.lock(); defer { lock.unlock() }; return _sinks }
            set { lock.lock(); _sinks = newValue; lock.unlock() }
        }
    }
}

enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    static let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    static let sessionID = UUID().uuidString

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
