import XCTest
@testable import Toolbox

final class LogStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore() throws -> LogStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox.logstore.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try LogStore(at: folder.appendingPathComponent(LogStore.fileName))
    }

    private func event(_ level: LogLevel, _ message: String = "Download failed", hoursAgo: Double = 0, version: String = "0.12.4",
                       metadata: [String: String] = ["error_domain": "NSURLErrorDomain", "error_code": "-1009"]) -> LogEvent {
        LogEvent(timestamp: now.addingTimeInterval(-hoursAgo * 3600), level: level, category: "download", message: message,
                 metadata: metadata, appVersion: version, osVersion: "macOS 26", installID: "i", sessionID: "s")
    }

    private func resolution(_ outcome: LogResolution.Outcome, for signature: String, version: String? = nil,
                            links: [String] = ["https://github.com/stozo04/Mac-Toolbox/pull/57"], at seconds: TimeInterval = 0) -> LogResolution {
        LogResolution(signature: signature, outcome: outcome, links: links.compactMap(URL.init(string:)), note: "Retry on a dropped connection",
                      decidedAt: now.addingTimeInterval(seconds), fixedInVersion: version)
    }

    // MARK: Signatures

    func testSignatureMatchesTheLogFixersGrouping() {
        XCTAssertEqual(event(.error).signature, "download | Download failed | NSURLErrorDomain | -1009")
        let timeout = event(.warning, "Program timed out", metadata: ["error_domain": "Toolbox.Shell.ShellError", "error_code": "1", "program": "diskutil"])
        XCTAssertEqual(timeout.signature, "download | Program timed out | Toolbox.Shell.ShellError | 1 | program=diskutil")
        XCTAssertEqual(event(.info, "Opened page", metadata: [:]).signature, "download | Opened page |  | ")
    }

    func testTheVaultIndexKeepsItsErrorDomainSoOldFixesStillMatch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox.no-folder.\(UUID().uuidString)/x/index.sqlite")
        XCTAssertThrowsError(try VaultIndex(at: file)) { error in
            XCTAssertEqual((error as NSError).domain, "Toolbox.VaultIndexError")
        }
    }

    // MARK: Events

    func testEventsRoundTripNewestFirst() throws {
        let store = try makeStore()
        try store.append(event(.warning, "older", hoursAgo: 2))
        try store.append(event(.error, "newer", hoursAgo: 1))
        let logs = try store.events(since: nil, levels: Set(LogLevel.allCases), limit: 10)
        XCTAssertEqual(logs.map(\.event.message), ["newer", "older"])
        let newest = try XCTUnwrap(logs.first)
        XCTAssertEqual(newest.event, event(.error, "newer", hoursAgo: 1))
        XCTAssertEqual(newest.signature, newest.event.signature)
    }

    func testRangeAndLevelsFilterTheEventsAndCountsFollowOnlyTheRange() throws {
        let store = try makeStore()
        try store.append(event(.critical, hoursAgo: 0.5))
        try store.append(event(.error, hoursAgo: 3))
        try store.append(event(.warning, hoursAgo: 3))
        try store.append(event(.info, hoursAgo: 30))
        let fourHours = LogRange.fourHours.start(now: now)
        XCTAssertEqual(try store.events(since: fourHours, levels: Set(LogLevel.allCases), limit: 10).count, 3)
        XCTAssertEqual(try store.events(since: fourHours, levels: [.error, .critical], limit: 10).map(\.event.level), [.critical, .error])
        XCTAssertEqual(try store.events(since: nil, levels: [], limit: 10), [])
        XCTAssertEqual(try store.counts(since: fourHours), [.critical: 1, .error: 1, .warning: 1])
        XCTAssertEqual(try store.counts(since: nil)[.info], 1)
        XCTAssertEqual(try store.events(since: nil, levels: Set(LogLevel.allCases), limit: 2).count, 2)
    }

    func testOldEventsAreTrimmed() throws {
        let store = try makeStore()
        try store.append(event(.error, "ancient", hoursAgo: 24 * 91))
        try store.append(event(.error, "recent", hoursAgo: 1))
        try store.deleteEvents(olderThan: now.addingTimeInterval(-LogStore.keepFor))
        XCTAssertEqual(try store.events(since: nil, levels: Set(LogLevel.allCases), limit: 10).map(\.event.message), ["recent"])
    }

    func testTheSinkSavesEveryEventInOrder() throws {
        let store = try makeStore()
        let sink = LogStoreSink(store: store, now: now)
        for index in 0..<20 { sink.write(event(.info, "event \(index)", hoursAgo: Double(20 - index) / 100)) }
        sink.drain()
        let messages = try store.events(since: nil, levels: Set(LogLevel.allCases), limit: 100).map(\.event.message)
        XCTAssertEqual(messages, (0..<20).reversed().map { "event \($0)" })
    }

    // MARK: Resolutions

    func testTheNewestDecisionWinsAndOnlyGitHubLinksAreKept() throws {
        let store = try makeStore()
        let signature = event(.error).signature
        try store.record(resolution(.fixProposed, for: signature))
        try store.record(resolution(.fixed, for: signature, version: "0.12.5",
                                    links: ["https://github.com/stozo04/Mac-Toolbox/pull/57", "https://evil.example/pull/1",
                                            "http://github.com/stozo04/Mac-Toolbox/pull/2"], at: 60))
        let latest = try XCTUnwrap(try store.latestResolutions()[signature])
        XCTAssertEqual(latest.outcome, .fixed)
        XCTAssertEqual(latest.fixedInVersion, "0.12.5")
        XCTAssertEqual(latest.links.map(\.absoluteString), ["https://github.com/stozo04/Mac-Toolbox/pull/57"])
    }

    func testStatusFollowsTheFixAndTheVersionItShippedIn() {
        let before = StoredLog(id: 1, event: event(.error, version: "0.12.4"), signature: event(.error).signature)
        let after = StoredLog(id: 2, event: event(.error, version: "0.12.10"), signature: event(.error).signature)
        let info = StoredLog(id: 3, event: event(.info), signature: event(.info).signature)
        let fixed = resolution(.fixed, for: before.signature, version: "0.12.9")
        XCTAssertEqual(LogStatus.of(before, resolution: nil), .open)
        XCTAssertNil(LogStatus.of(info, resolution: nil), "info events are not problems")
        XCTAssertEqual(LogStatus.of(before, resolution: fixed), .fixed)
        XCTAssertEqual(LogStatus.of(after, resolution: fixed), .cameBack, "0.12.10 is newer than 0.12.9")
        XCTAssertEqual(LogStatus.of(after, resolution: resolution(.fixed, for: before.signature)), .fixed, "no version yet: nothing came back")
        XCTAssertEqual(LogStatus.of(after, resolution: resolution(.loggingImproved, for: before.signature, version: "0.12.9")), .open)
        XCTAssertEqual(LogStatus.of(before, resolution: resolution(.loggingImproved, for: before.signature, version: "0.12.9")), .loggingImproved)
        XCTAssertEqual(LogStatus.of(before, resolution: resolution(.watching, for: before.signature)), .watching)
        XCTAssertEqual(LogStatus.of(before, resolution: resolution(.fixProposed, for: before.signature)), .fixProposed)
        XCTAssertEqual(LogStatus.of(before, resolution: resolution(.needsHuman, for: before.signature)), .needsHuman)
    }

    func testVersionsCompareNumberByNumber() throws {
        XCTAssertLessThan(try XCTUnwrap(VersionNumber("0.12.9")), try XCTUnwrap(VersionNumber("0.12.10")))
        XCTAssertEqual(try XCTUnwrap(VersionNumber("1.2")), try XCTUnwrap(VersionNumber("1.2.0")))
        XCTAssertNil(VersionNumber("dev"))
    }

    // MARK: Where the log lives

    func testOnlyTheInstalledAppUsesTheRealLog() {
        XCTAssertEqual(LogStoreLocation.launch(arguments: [], isDevelopmentRun: false), LogStoreLocation.standard)
        XCTAssertEqual(LogStoreLocation.launch(arguments: [], isDevelopmentRun: true), LogStoreLocation.development)
        XCTAssertEqual(LogStoreLocation.launch(arguments: ["Toolbox", "--log-store", "/tmp/x.sqlite"], isDevelopmentRun: true),
                       URL(fileURLWithPath: "/tmp/x.sqlite"))
        XCTAssertNotEqual(LogStoreLocation.standard, LogStoreLocation.development)
    }

    // MARK: The page

    @MainActor
    func testThePageFiltersByLevelAndStatusAndKeepsCountsForTheRange() throws {
        let store = try makeStore()
        try store.append(event(.critical, "disk vanished", hoursAgo: 1, metadata: [:]))
        try store.append(event(.error, hoursAgo: 2))
        try store.append(event(.info, "Opened page", hoursAgo: 2, metadata: [:]))
        try store.append(event(.error, hoursAgo: 30))
        try store.record(resolution(.fixed, for: event(.error).signature, version: "0.12.5"))
        let model = LogsModel(store: store, now: { self.now })
        model.range = .fourHours
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.counts, [.critical: 1, .error: 1, .info: 1])

        model.toggle(.error)
        XCTAssertEqual(model.rows.map(\.event.level), [.error])
        XCTAssertEqual(model.counts[.critical], 1, "counts ignore the level filter")
        model.toggle(.critical)
        XCTAssertEqual(model.rows.map(\.event.level), [.critical, .error])
        model.toggle(.critical)
        model.toggle(.error)
        XCTAssertTrue(model.showsEveryLevel, "taking away the last level shows them all again")

        model.status = .fixed
        XCTAssertEqual(model.rows.map(\.event.message), ["Download failed"])
        model.status = .open
        XCTAssertEqual(model.rows.map(\.event.message), ["disk vanished"], "info events have no status")
        model.status = nil
        model.range = .all
        XCTAssertEqual(model.totalInRange, 4)
    }

    @MainActor
    func testAStatusFindsOlderProblemsBehindMoreThanTheRowLimit() throws {
        let store = try makeStore()
        try store.append(event(.error, "old and open", hoursAgo: 10, metadata: [:]))
        for index in 0...LogsModel.rowLimit { try store.append(event(.info, "page \(index)", hoursAgo: 1, metadata: [:])) }
        let model = LogsModel(store: store, now: { self.now })
        model.reload()
        XCTAssertTrue(model.reachedLimit)
        XCTAssertFalse(model.rows.contains { $0.event.message == "old and open" })
        model.status = .open
        XCTAssertEqual(model.rows.map(\.event.message), ["old and open"])
        XCTAssertFalse(model.reachedLimit)
    }

    @MainActor
    func testCopyAsMarkdownCarriesTheEvidenceAndTheFix() throws {
        let store = try makeStore()
        try store.append(event(.error))
        try store.record(resolution(.fixed, for: event(.error).signature, version: "0.12.5"))
        let model = LogsModel(store: store, now: { self.now })
        model.reload()
        let row = try XCTUnwrap(model.rows.first)
        let pasteboard = makeScratchPasteboard()
        model.copyMarkdown(of: row, to: pasteboard)
        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(text.hasPrefix("**error** · download · 2027-01-15 08:00:00 UTC · v0.12.4"), text)
        XCTAssertTrue(text.contains("> Download failed"))
        XCTAssertTrue(text.contains("Signature: `download | Download failed | NSURLErrorDomain | -1009`"))
        XCTAssertTrue(text.contains("Status: Fixed in v0.12.5 (https://github.com/stozo04/Mac-Toolbox/pull/57)"))
        XCTAssertTrue(text.contains("error_code: -1009"))
    }
}
