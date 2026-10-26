import XCTest
@testable import Toolbox

private final class MemorySink: LogSink, @unchecked Sendable {
    let minimumLevel: LogLevel
    private let lock = NSLock()
    private var _events: [LogEvent] = []
    init(minimumLevel: LogLevel) { self.minimumLevel = minimumLevel }
    func write(_ event: LogEvent) { lock.lock(); _events.append(event); lock.unlock() }
    var events: [LogEvent] { lock.lock(); defer { lock.unlock() }; return _events }
}

final class LoggingTests: XCTestCase {
    func testLevelsAreOrdered() {
        XCTAssertLessThan(LogLevel.info, .warning)
        XCTAssertLessThan(LogLevel.warning, .error)
        XCTAssertLessThan(LogLevel.error, .critical)
    }

    func testSinksOnlyReceiveEventsAtOrAboveTheirLevel() {
        let all = MemorySink(minimumLevel: .info), serious = MemorySink(minimumLevel: .error)
        Log.configure(sinks: [all, serious])
        defer { Log.configure(sinks: []) }
        Log.info("a"); Log.warning("b"); Log.error("c", category: "x", ["k": "v"]); Log.critical("d")
        XCTAssertEqual(all.events.map(\.message), ["a", "b", "c", "d"])
        XCTAssertEqual(serious.events.map(\.message), ["c", "d"])
        XCTAssertEqual(serious.events[0].category, "x")
        XCTAssertEqual(serious.events[0].metadata, ["k": "v"])
    }

    func testSupabaseRequestShape() throws {
        let config = SupabaseLogConfig(url: URL(string: "https://abc.supabase.co")!, key: "pub")
        let sink = SupabaseLogSink(config: config, flushInterval: 3600)
        let event = LogEvent(timestamp: Date(timeIntervalSince1970: 0), level: .error, category: "download",
                             message: "m", metadata: ["host": "youtu.be"], appVersion: "1", osVersion: "os",
                             installID: "i", sessionID: "s")
        let req = try sink.request(for: [event])
        XCTAssertEqual(req.url?.absoluteString, "https://abc.supabase.co/rest/v1/mactoolkit_app_logs")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "pub")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer pub")
        let json = try JSONSerialization.jsonObject(with: req.httpBody!) as! [[String: Any]]
        XCTAssertEqual(json[0]["level"] as? String, "error")
        XCTAssertEqual(json[0]["install_id"] as? String, "i")
        XCTAssertEqual(json[0]["timestamp"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual((json[0]["metadata"] as? [String: String])?["host"], "youtu.be")
    }
}

/// Hits the real table using ~/Library/Application Support/Toolbox/logging.json.
/// Run with: TOOLBOX_LOG_LIVE=1 swift test --filter LoggingLiveTests
final class LoggingLiveTests: XCTestCase {
    func testErrorReachesSupabase() async throws {
        guard ProcessInfo.processInfo.environment["TOOLBOX_LOG_LIVE"] != nil,
              let config = SupabaseLogConfig.load() else { throw XCTSkip("Set TOOLBOX_LOG_LIVE=1") }
        Log.configure(sinks: [SupabaseLogSink(config: config, minimumLevel: .warning)])
        defer { Log.configure(sinks: []) }
        Log.error("live sink test", category: "live-test", ["host": "example.com"])
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }
}
