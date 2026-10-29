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
        XCTAssertEqual(serious.events[0].metadata["k"], "v")
        XCTAssertNotNil(serious.events[0].metadata["page"], "failures always say where the user was")
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

    // MARK: Dev runs stay out of Supabase

    func testDevelopmentRunsDoNotSendRemoteLogs() {
        XCTAssertFalse(AppInfo.sendsRemoteLogs(environment: [:], isDevelopmentRun: true))
        XCTAssertTrue(AppInfo.sendsRemoteLogs(environment: [:], isDevelopmentRun: false))
        XCTAssertTrue(AppInfo.sendsRemoteLogs(environment: ["TOOLBOX_LOG_REMOTE": "1"], isDevelopmentRun: true))
        XCTAssertTrue(AppInfo.isDevelopmentRun, "tests run as a debug build, so they must never count as the installed app")
    }

    // MARK: Failures carry enough to understand them

    func testDetailsDescribeTheErrorAndTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Holiday Photo.HEIC")
        try Data(count: 2048).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let error = NSError(domain: "ImageIO", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "The file could not be decoded.",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "No such file"]),
        ])
        let m = Log.details(error, file: file, ["to": "webp"])
        XCTAssertEqual(m["error_domain"], "ImageIO")
        XCTAssertEqual(m["error_code"], "4")
        XCTAssertEqual(m["error_description"], "The file could not be decoded.")
        XCTAssertEqual(m["underlying"], "NSPOSIXErrorDomain 2: No such file")
        XCTAssertEqual(m["file_name"], "Holiday Photo.HEIC")
        XCTAssertEqual(m["file_ext"], "heic")
        XCTAssertEqual(m["file_bytes"], "2048")
        XCTAssertEqual(m["to"], "webp")
        XCTAssertNil(m.values.first { $0.contains(NSTemporaryDirectory()) }, "folders are not logged, only the file name")
    }

    func testAccountNameAndLinkSecretsAreScrubbed() {
        XCTAssertEqual(LogText.clean("can't open /Users/steven/Movies/a.mov", limit: 100), "can't open /Users/me/Movies/a.mov")
        let url = URL(string: "https://user:pw@example.com/watch/abc?token=SECRET&v=1#frag")!
        XCTAssertEqual(LogText.safeURL(url), "https://example.com/watch/abc")
    }

    func testFailuresGetThePageAndTheStepsBeforeThem() {
        let sink = MemorySink(minimumLevel: .info)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        Log.navigate(to: "Images/Convert Images")
        Log.info("Image converted", category: "convert-images")
        Log.error("Image conversion failed", category: "convert-images")
        let failure = sink.events.last!
        XCTAssertEqual(failure.metadata["page"], "Images/Convert Images")
        let recent = failure.metadata["recent"] ?? ""
        XCTAssertTrue(recent.contains("[nav] Opened page"))
        XCTAssertTrue(recent.contains("[convert-images] Image converted"))
        XCTAssertNil(sink.events.first { $0.level == .info }?.metadata["recent"], "info events stay small")
    }

    func testOversizedEventsAreTrimmedToTheTableLimits() {
        let huge = String(repeating: "x", count: 5000)
        let event = LogEvent(timestamp: Date(), level: .error, category: String(repeating: "c", count: 200), message: huge,
                             metadata: Dictionary(uniqueKeysWithValues: (0..<30).map { ("k\($0)", huge) }) .merging(["recent": huge]) { a, _ in a },
                             appVersion: "1", osVersion: "os", installID: "i", sessionID: "s").fitted()
        XCTAssertLessThanOrEqual(event.category.count, 64)
        XCTAssertLessThanOrEqual(event.message.count, 500)
        let bytes = event.metadata.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        XCTAssertLessThan(bytes, 4096)
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
