import AppKit
import Foundation
import os

/// Which `logs.sqlite` this run uses. The installed app keeps the real log; anything run from the project keeps its
/// own, so experiments never mix into what the log fixer reads.
enum LogStoreLocation {
    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Toolbox")

    static let standard = folder.appendingPathComponent(LogStore.fileName)
    static let development = folder.appendingPathComponent("logs-dev.sqlite")

    static let debugFileFlag = "--log-store"

    /// Debug builds may point at another file with `--log-store <file>`.
    static func launch(arguments: [String] = CommandLine.arguments, isDevelopmentRun: Bool = AppInfo.isDevelopmentRun) -> URL {
        #if DEBUG
        if let flag = arguments.firstIndex(of: debugFileFlag), flag + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[flag + 1])
        }
        #endif
        return isDevelopmentRun ? development : standard
    }
}

/// Saves every event to the log store, off the caller's thread and in order. Old events are trimmed once at launch.
final class LogStoreSink: LogSink, @unchecked Sendable {
    let minimumLevel: LogLevel = .info
    private let store: LogStore
    private let queue = DispatchQueue(label: "toolbox.log-store")
    // A failed save must not go through `Log`, which would try to save it again.
    private let failures = os.Logger(subsystem: "com.toolbox.app", category: "log-store")
    private var quitObserver: NSObjectProtocol?

    init(store: LogStore, now: Date = Date()) {
        self.store = store
        queue.async { [store, failures] in
            do { try store.deleteEvents(olderThan: now.addingTimeInterval(-LogStore.keepFor)) } catch {
                failures.error("Trimming the log store failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: nil) { [weak self] _ in self?.drain() }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    func write(_ event: LogEvent) {
        queue.async { [store, failures] in
            do { try store.append(event) } catch {
                failures.error("Saving a log event failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits until every event written so far is saved.
    func drain() { queue.sync {} }
}
