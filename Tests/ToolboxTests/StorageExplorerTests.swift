import XCTest
@testable import Toolbox

final class StorageExplorerTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("storage-test-\(UUID().uuidString)")
        for dir in ["Library/Caches/com.big.app", "Library/Caches/com.small.app", "Library/Caches/Homebrew/downloads", "Downloads", ".Trash"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 300_000).write(to: home.appendingPathComponent("Library/Caches/com.big.app/blob"))
        try Data(repeating: 1, count: 20_000).write(to: home.appendingPathComponent("Library/Caches/com.small.app/blob"))
        try Data(repeating: 1, count: 100_000).write(to: home.appendingPathComponent("Library/Caches/Homebrew/downloads/pkg.tar"))
        try Data(repeating: 1, count: 50_000).write(to: home.appendingPathComponent("Downloads/installer.dmg"))
        try Data(repeating: 1, count: 40_000).write(to: home.appendingPathComponent(".Trash/old.zip"))
    }

    override func tearDownWithError() throws {
        // A test may leave a folder unreadable.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appendingPathComponent("Library/Caches/locked").path)
        try? fm.removeItem(at: home)
    }

    private func hog(_ id: String, now: Date = Date()) throws -> SpaceHog { try XCTUnwrap(SpaceHog.all(home: home, now: now).first { $0.id == id }) }

    func testListMatchesTheDesign() {
        let hogs = SpaceHog.all(home: home)
        XCTAssertEqual(hogs.map(\.title), ["iOS Simulators", "App Caches", "Homebrew Downloads", "Docker", "iPhone and iPad Backups", "Trash", "Old Downloads"])
        XCTAssertEqual(Set(hogs.map(\.id)).count, hogs.count)
    }

    func testAppCachesExcludeHomebrewSoItIsNotCountedTwice() throws {
        let r = StorageScanner.measure(try hog("caches"))
        XCTAssertEqual(Set(r.items.map { $0.url.lastPathComponent }), ["com.big.app", "com.small.app"])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(r.items.first).bytes, try r.items.element(at: 1).bytes, "biggest first")
        XCTAssertGreaterThanOrEqual(r.total, 320_000)
        XCTAssertEqual(StorageScanner.measure(try hog("homebrew")).items.map { $0.url.lastPathComponent }, ["pkg.tar"])
    }

    func testMissingFolderIsEmptyAndUnreadableFolderNeedsAccess() throws {
        XCTAssertEqual(StorageScanner.measure(try hog("docker")), HogResult(items: [], needsAccess: false))
        let locked = home.appendingPathComponent("Library/Caches/locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        let probe = SpaceHog(id: "t", title: "t", detail: "", symbol: "x", root: locked, clearing: .trash)
        XCTAssertTrue(StorageScanner.measure(probe).needsAccess)
    }

    func testOldDownloadsUsesTheNinetyDayCutoff() {
        XCTAssertTrue(StorageScanner.measure(try hog("downloads")).items.isEmpty, "a file added just now is not old")
        let later = Date().addingTimeInterval(100 * 24 * 3600)
        XCTAssertEqual(StorageScanner.measure(try hog("downloads", now: later)).items.map { $0.url.lastPathComponent }, ["installer.dmg"])
    }

    func testItemsMustBeInsideTheFolder() {
        let root = home.appendingPathComponent("Library/Caches")
        XCTAssertTrue(StorageCleaner.isInside(root.appendingPathComponent("a"), root: root))
        XCTAssertFalse(StorageCleaner.isInside(root, root: root), "the folder itself is never cleared")
        XCTAssertFalse(StorageCleaner.isInside(home.appendingPathComponent("Documents/x"), root: root))
        XCTAssertFalse(StorageCleaner.isInside(URL(fileURLWithPath: root.path + "/../Documents/x"), root: root))
        XCTAssertFalse(StorageCleaner.isInside(URL(fileURLWithPath: root.path + "-evil/x"), root: root), "a sibling with the same prefix")
    }

    func testClearingUsesTheRightActionPerKind() throws {
        var trashed: [String] = [], deleted: [String] = []
        let item = { (hog: SpaceHog, name: String) in HogItem(url: hog.root.appendingPathComponent(name), bytes: 10) }
        let caches = try hog("caches"), trash = try hog("trash"), docker = try hog("docker")

        var o = StorageCleaner.clear([item(caches, "a")], from: caches, trash: { trashed.append($0.lastPathComponent) }, delete: { deleted.append($0.lastPathComponent) })
        XCTAssertEqual(trashed, ["a"]); XCTAssertTrue(deleted.isEmpty); XCTAssertEqual(o.freed, 10)

        o = StorageCleaner.clear([item(trash, "b")], from: trash, trash: { trashed.append($0.lastPathComponent) }, delete: { deleted.append($0.lastPathComponent) })
        XCTAssertEqual(deleted, ["b"]); XCTAssertEqual(trashed, ["a"])

        o = StorageCleaner.clear([item(docker, "Docker.raw")], from: docker, trash: { _ in XCTFail() }, delete: { _ in XCTFail() })
        XCTAssertEqual(o.failures, ["Docker.raw"]); XCTAssertEqual(o.freed, 0)

        o = StorageCleaner.clear([HogItem(url: home.appendingPathComponent("Documents/secret"), bytes: 5)], from: caches, trash: { _ in XCTFail() }, delete: { _ in XCTFail() })
        XCTAssertEqual(o.failures, ["secret"], "outside the folder: refused")
    }

    func testFailureIsReportedAndTheRestStillRun() throws {
        struct Nope: Error {}
        let caches = try hog("caches")
        let items = ["a", "b"].map { HogItem(url: caches.root.appendingPathComponent($0), bytes: 7) }
        let o = StorageCleaner.clear(items, from: caches, trash: { if $0.lastPathComponent == "a" { throw Nope() } }, delete: { _ in })
        XCTAssertEqual(o.failures, ["a"])
        XCTAssertEqual(o.freed, 7)
    }

    @MainActor func testModelMeasuresClearsAndRemeasures() async throws {
        let m = StorageExplorerModel(hogs: SpaceHog.all(home: home),
                                     trash: { try FileManager.default.removeItem(at: $0) }, // stands in for the Trash
                                     delete: { try FileManager.default.removeItem(at: $0) })
        m.measureAll()
        try await waitUntil(timeout: .seconds(60), "every space hog is measured") { !m.isMeasuring && m.measures.count >= 7 }
        let before = m.found
        XCTAssertGreaterThanOrEqual(before, 320_000 + 100_000 + 40_000)
        let caches = try XCTUnwrap(m.hogs.first { $0.id == "caches" })
        m.open(caches)
        let big = try XCTUnwrap(m.result(caches)?.items.first)
        m.toggle(big)
        XCTAssertEqual(m.selectedBytes, big.bytes)
        m.clearSelected()
        try await waitUntil(timeout: .seconds(60), "the caches are measured again") { m.measures["caches"] != .measuring }
        XCTAssertEqual(m.lastOutcome?.freed, big.bytes)
        XCTAssertFalse(fm.fileExists(atPath: big.url.path))
        XCTAssertEqual(m.result(caches)?.items.count, 1)
        XCTAssertTrue(m.selection.isEmpty)
        XCTAssertLessThan(m.found, before)
    }

    @MainActor func testExplorerSortsBySizeAndStopsAtHome() async throws {
        let e = FolderExplorer(home: home)
        e.go(to: home.appendingPathComponent("Library/Caches"))
        try await waitUntil(timeout: .seconds(60), "every entry has a size") { !e.entries.contains(where: { $0.bytes == nil }) }
        XCTAssertEqual(e.entries.first?.url.lastPathComponent, "com.big.app")
        XCTAssertTrue(e.entries.first?.isFolder ?? false)
        XCTAssertTrue(e.canGoUp)
        e.go(to: home)
        XCTAssertFalse(e.canGoUp)
        e.goUp()
        XCTAssertEqual(e.location.standardizedFileURL.path, home.standardizedFileURL.path)
    }

    func testDiskUsageAddsUp() throws {
        let d = try XCTUnwrap(StorageScanner.diskUsage())
        XCTAssertGreaterThan(d.total, 0)
        XCTAssertEqual(d.used + d.purgeable + d.free, d.total)
    }

    func testDirectorySizeCountsEverythingAndIgnoresSymlinks() throws {
        let dir = home.appendingPathComponent("sized")
        try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: dir.appendingPathComponent("sub/a"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: home.appendingPathComponent("Library"))
        let size = DirectorySize.bytes(of: dir)
        XCTAssertGreaterThanOrEqual(size, 100_000)
        XCTAssertLessThan(size, 200_000, "the linked Library folder is not followed")
        XCTAssertEqual(DirectorySize.bytes(of: dir.appendingPathComponent("missing")), 0)
    }

    // MARK: Clearing and measuring that overlap

    private final class Hold: @unchecked Sendable {
        private let armed = Locked(false)
        private let holding = Locked(false)
        private let gate = DispatchSemaphore(value: 0)

        var isHolding: Bool { holding.value }

        func arm() { armed.set(true) }

        func passOrWait() {
            var shouldHold = false
            armed.update { shouldHold = $0; $0 = false }
            guard shouldHold else { return }
            holding.set(true)
            gate.wait()
        }

        func release() { gate.signal() }
    }

    @MainActor private func measuredCaches(trash: @escaping @Sendable (URL) throws -> Void) async throws -> (StorageExplorerModel, SpaceHog) {
        let model = StorageExplorerModel(hogs: SpaceHog.all(home: home), trash: trash, delete: { try FileManager.default.removeItem(at: $0) })
        model.measureAll()
        try await waitUntil(timeout: .seconds(60), "every space hog is measured") { !model.isMeasuring }
        let caches = try XCTUnwrap(model.hogs.first { $0.id == "caches" })
        model.open(caches)
        model.toggle(try XCTUnwrap(model.result(caches)?.items.first))
        return (model, caches)
    }

    @MainActor func testClearingRunsOffTheMainThreadAndShowsThatItIsClearing() async throws {
        let ranOnMain = Locked<Bool?>(nil)
        let hold = Hold()
        addTeardownBlock { hold.release() }
        hold.arm()
        let (model, caches) = try await measuredCaches { url in
            ranOnMain.set(Thread.isMainThread)
            hold.passOrWait()
            try FileManager.default.removeItem(at: url)
        }

        model.clearSelected()

        XCTAssertTrue(model.isClearing)
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertNil(model.lastOutcome)
        try await waitUntil("the clearing reaches the Trash step") { hold.isHolding }
        XCTAssertEqual(ranOnMain.value, false, "moving files to the Trash must not block the main thread")
        model.clearSelected()
        hold.release()
        try await waitUntil(timeout: .seconds(60), "the caches are cleared and measured again") { !model.isClearing && !model.isMeasuring }
        XCTAssertEqual(model.lastOutcome?.failures, [])
        XCTAssertEqual(model.result(caches)?.items.count, 1)
    }

    @MainActor func testAnOutcomeIsNotShownOnAnotherSpaceHogOpenedMeanwhile() async throws {
        let hold = Hold()
        addTeardownBlock { hold.release() }
        hold.arm()
        let (model, _) = try await measuredCaches { url in
            hold.passOrWait()
            try FileManager.default.removeItem(at: url)
        }
        model.clearSelected()
        try await waitUntil("the clearing reaches the Trash step") { hold.isHolding }

        model.open(try XCTUnwrap(model.hogs.first { $0.id == "homebrew" }))
        XCTAssertEqual(model.clearingHogID, "caches")
        hold.release()
        try await waitUntil(timeout: .seconds(60), "the caches are cleared and measured again") { !model.isClearing && !model.isMeasuring }

        XCTAssertNil(model.lastOutcome)
    }

    @MainActor func testAMeasurementStartedEarlierDoesNotReplaceANewerOne() async throws {
        let root = home.appendingPathComponent("hog")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: root.appendingPathComponent("a"))
        let hold = Hold()
        addTeardownBlock { hold.release() }
        let hog = SpaceHog(id: "held", title: "Held", detail: "", symbol: "folder", root: root, clearing: .trash) { _ in
            hold.passOrWait()
            return true
        }
        let model = StorageExplorerModel(hogs: [hog], trash: { _ in }, delete: { _ in })
        let names = { model.result(hog)?.items.map(\.url.lastPathComponent).sorted() }
        model.measureAll()
        try await waitUntil("the folder is measured") { names() == ["a"] }
        model.open(hog)
        hold.arm()
        model.clearSelected()
        try await waitUntil("the measurement after clearing is under way") { hold.isHolding }

        try Data(repeating: 1, count: 2000).write(to: root.appendingPathComponent("b"))
        model.measureAll()
        try await waitUntil("the newer measurement arrives") { names() == ["a", "b"] }
        hold.release()
        try await pause(for: .milliseconds(300), because: "the older measurement would land once its scan finishes")

        XCTAssertEqual(names(), ["a", "b"])
    }
}
