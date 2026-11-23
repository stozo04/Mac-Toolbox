import XCTest
@testable import Toolbox

final class MemorySink: LogSink, @unchecked Sendable {
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
        XCTAssertEqual(try XCTUnwrap(serious.events.first).category, "x")
        XCTAssertEqual(try XCTUnwrap(serious.events.first).metadata["k"], "v")
        XCTAssertNotNil(try XCTUnwrap(serious.events.first).metadata["page"], "failures always say where the user was")
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

    func testCleanCutsEveryLinkBackToItsPath() {
        XCTAssertEqual(LogText.clean("ERROR: Unsupported URL: https://example.com/watch?v=1&sig=SECRETTOKEN", limit: 400),
                       "ERROR: Unsupported URL: https://example.com/watch")
        XCTAssertEqual(LogText.clean("first https://a.example/x?t=ONE then HTTP://b.example/y/z#TWO and https://c.example", limit: 400),
                       "first https://a.example/x then HTTP://b.example/y/z and https://c.example")
        XCTAssertEqual(LogText.clean("Could not reach https://example.com/feed?key=SECRET.", limit: 400), "Could not reach https://example.com/feed.")
        XCTAssertEqual(LogText.clean("(see https://example.com/a?b=SECRET), then stop", limit: 400), "(see https://example.com/a), then stop")
        XCTAssertEqual(LogText.clean("link \"https://example.com/a?b=SECRET\" and 'https://example.com/c#SECRET'", limit: 400),
                       "link \"https://example.com/a\" and 'https://example.com/c'")
        XCTAssertEqual(LogText.clean("https://user:SECRET@example.com/private/file.mp4", limit: 400), "https://example.com/private/file.mp4")
        XCTAssertEqual(LogText.clean("https://example.com/user@home/file", limit: 400), "https://example.com/user@home/file")
        XCTAssertEqual(LogText.clean("https://example.com?mail=jane@other.example", limit: 400), "https://example.com")
        XCTAssertEqual(LogText.clean("https://example.com#jane@other.example", limit: 400), "https://example.com")
    }

    func testCleanLeavesTextWithoutALinkQueryAlone() {
        XCTAssertEqual(LogText.clean("The file could not be opened.", limit: 400), "The file could not be opened.")
        XCTAssertEqual(LogText.clean("can't read /Volumes/Disk/What?.mov#1", limit: 400), "can't read /Volumes/Disk/What?.mov#1")
        XCTAssertEqual(LogText.clean("https://example.com/plain/path.", limit: 400), "https://example.com/plain/path.")
    }

    func testCleanCutsALinkBeforeItShortensTheText() {
        let cleaned = LogText.clean("https://example.com/watch?sig=SECRETTOKEN " + String(repeating: "x", count: 100), limit: 40)
        XCTAssertEqual(cleaned.count, 40)
        XCTAssertTrue(cleaned.hasPrefix("https://example.com/watch xxx"))
        XCTAssertEqual(LogText.clean(cleaned, limit: 40), cleaned)
    }

    func testDetailsOfADownloadFailureCarryNoLinkQuery() {
        let stderr = "WARNING: something\nERROR: Unsupported URL: https://example.com/watch?v=1&sig=SECRETTOKEN\n"
        let error = DownloadError.failed(YtDlpCommand.friendlyError(from: stderr))
        XCTAssertTrue(error.localizedDescription.contains("SECRETTOKEN"), "the message shown to the user keeps yt-dlp's wording")

        let details = Log.details(error)
        XCTAssertEqual(details["error_description"], "Unsupported URL: https://example.com/watch")
        for (key, value) in details {
            XCTAssertFalse(value.contains("SECRETTOKEN"), "\(key) carries the query string: \(value)")
        }
        let fitted = LogEvent(timestamp: Date(), level: .error, category: "download", message: "Download failed", metadata: details,
                              appVersion: "1", osVersion: "os", installID: "i", sessionID: "s").fitted()
        for (key, value) in fitted.metadata {
            XCTAssertFalse(value.contains("SECRETTOKEN"), "after fitting, \(key) still carries the query string")
        }
    }

    func testFailuresGetThePageAndTheStepsBeforeThem() throws {
        let sink = MemorySink(minimumLevel: .info)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        Log.navigate(to: "Images/Convert Images")
        Log.info("Image converted", category: "convert-images")
        Log.error("Image conversion failed", category: "convert-images")
        let failure = try XCTUnwrap(sink.events.last)
        XCTAssertEqual(failure.metadata["page"], "Images/Convert Images")
        let recent = failure.metadata["recent"] ?? ""
        XCTAssertTrue(recent.contains("[nav] Opened page"))
        XCTAssertTrue(recent.contains("[convert-images] Image converted"))
        XCTAssertNil(sink.events.first { $0.level == .info }?.metadata["recent"], "info events stay small")
    }

    func testOversizedEventsAreTrimmedToTheirLimits() {
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
