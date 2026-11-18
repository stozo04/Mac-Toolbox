import XCTest
@testable import Toolbox

private enum JobStatus: BatchStatus {
    case waiting
    case working(Double)
    case done(String)
    case failed(String)

    var isFailed: Bool { if case .failed = self { true } else { false } }
}

private struct Job: BatchItem {
    let id = UUID()
    let url: URL
    var status = JobStatus.waiting

    var name: String { url.lastPathComponent }
}

private struct JobError: LocalizedError {
    var errorDescription: String? { "The job broke." }
}

@MainActor
private final class Bench {
    private(set) var started: [String] = []
    private(set) var folders: [URL] = []
    private var finishers: [String: CheckedContinuation<String, Error>] = [:]
    private var reporters: [String: @Sendable (Double) -> Void] = [:]

    func work(_ job: Job, _ folder: URL, _ step: BatchQueue<Job>.Step) async throws -> JobStatus {
        started.append(job.name)
        folders.append(folder)
        reporters[job.name] = step.progress { .working($0) }
        let saved = try await withCheckedThrowingContinuation { finishers[job.name] = $0 }
        return .done(saved)
    }

    func isWorking(on name: String) -> Bool { finishers[name] != nil }

    func report(_ fraction: Double, for name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTUnwrap(reporters[name], file: file, line: line)(fraction)
    }

    func finish(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTUnwrap(finishers.removeValue(forKey: name), file: file, line: line).resume(returning: "saved \(name)")
    }

    func fail(_ name: String, with error: Error, file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTUnwrap(finishers.removeValue(forKey: name), file: file, line: line).resume(throwing: error)
    }
}

@MainActor
final class BatchQueueTests: XCTestCase {
    private var dir: URL!
    private var output: URL!
    private var queue: BatchQueue<Job>!
    private var bench: Bench!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("batch-queue-test-\(UUID())")
        output = dir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        queue = makeQueue(outputParent: output)
        bench = Bench()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func makeQueue(outputParent: URL) -> BatchQueue<Job> {
        let tool = BatchTool(outputFolderName: "Toolbox Test Jobs", logCategory: "batch-queue-test", failureLog: "Test job failed",
                             skippedBecause: "had no jobs") { $0.pathExtension == "job" ? [$0] : [] }
        return BatchQueue(tool, outputParent: outputParent)
    }

    private func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func add(_ names: String...) { queue.add(names.map(file)) { Job(url: $0) } }

    @discardableResult
    private func run(retryingFailed: Bool = true) -> Bool {
        let bench: Bench = bench
        return queue.run(retryingFailed: retryingFailed) { try await bench.work($0, $1, $2) }
    }

    private func status(of name: String, file: StaticString = #filePath, line: UInt = #line) throws -> JobStatus {
        try XCTUnwrap(queue.items.first { $0.name == name }, "\(name) is not in the queue", file: file, line: line).status
    }

    private func waitUntilWorking(on name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("\(name) is being worked on", file: file, line: line) { self.bench.isWorking(on: name) }
    }

    private func waitUntilIdle(file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("the run ends", file: file, line: line) { !self.queue.isRunning }
    }

    private func settle(_ reason: String) async throws {
        try await pause(for: .milliseconds(50), because: reason)
    }

    // MARK: Files

    func testAddQueuesTheAcceptedFilesAsWaitingAndReturnsThem() {
        let added = queue.add([file("a.job"), file("b.job")]) { Job(url: $0) }

        XCTAssertEqual(queue.items.map(\.name), ["a.job", "b.job"])
        XCTAssertEqual(added.map(\.id), queue.items.map(\.id))
        XCTAssertEqual(queue.items.map(\.status), [.waiting, .waiting])
        XCTAssertTrue(queue.hasItems)
        XCTAssertTrue(queue.hasWaiting)
        XCTAssertNil(queue.notice)
    }

    func testOneAddOfManyFilesCountsEverySkippedOneWhereverItSitsInTheList() {
        add("notes.txt", "a.job", "photo.png", "b.job")

        XCTAssertEqual(queue.items.map(\.name), ["a.job", "b.job"])
        XCTAssertEqual(queue.notice, "2 item(s) had no jobs and were skipped.")
    }

    func testAFileTheToolCannotReadIsSkippedToo() {
        queue.add([file("a.job"), file("broken.job")]) { $0.lastPathComponent == "broken.job" ? nil : Job(url: $0) }

        XCTAssertEqual(queue.items.map(\.name), ["a.job"])
        XCTAssertEqual(queue.notice, "1 item(s) had no jobs and were skipped.")
    }

    func testTheNextAddWithNothingSkippedClearsTheNotice() {
        add("notes.txt")
        XCTAssertNotNil(queue.notice)

        add("a.job")

        XCTAssertNil(queue.notice)
    }

    func testTheSameFileIsQueuedOnceHoweverItIsNamed() throws {
        try Data().write(to: file("a.job"))
        try FileManager.default.createSymbolicLink(at: file("link.job"), withDestinationURL: file("a.job"))

        add("a.job", "a.job", "link.job")
        add("a.job", "b.job")

        XCTAssertEqual(queue.items.map(\.name), ["a.job", "b.job"])
        XCTAssertNil(queue.notice, "a duplicate is not a skipped file")
    }

    func testRemoveTakesAnItemOutWhileIdle() throws {
        add("a.job", "b.job")

        XCTAssertTrue(queue.remove(try XCTUnwrap(queue.items.first).id))
        XCTAssertFalse(queue.remove(UUID()))

        XCTAssertEqual(queue.items.map(\.name), ["b.job"])
    }

    func testRemoveIsRefusedWhileRunning() async throws {
        add("a.job", "b.job")
        run()
        try await waitUntilWorking(on: "a.job")

        XCTAssertFalse(queue.remove(try XCTUnwrap(queue.items.last).id))
        queue.remove { _ in true }

        XCTAssertEqual(queue.items.map(\.name), ["a.job", "b.job"])
        try bench.finish("a.job")
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()
    }

    func testUpdateChangesOneItemAndIgnoresOneThatIsGone() throws {
        add("a.job")
        let id = try XCTUnwrap(queue.items.first).id

        queue.update(id) { $0.status = .done("by hand") }
        queue.update(UUID()) { $0.status = .failed("nobody") }

        XCTAssertEqual(queue.items.map(\.status), [.done("by hand")])
    }

    // MARK: Running

    func testRunWorksThroughTheWaitingItemsOneAtATimeInOrder() async throws {
        add("a.job", "b.job")

        XCTAssertTrue(run())
        XCTAssertTrue(queue.isRunning)
        XCTAssertFalse(run(), "a second run cannot start while one is going")
        try await waitUntilWorking(on: "a.job")
        XCTAssertEqual(try status(of: "a.job"), .working(0))
        XCTAssertEqual(try status(of: "b.job"), .waiting)
        XCTAssertEqual(bench.started, ["a.job"])
        try bench.finish("a.job")
        try await waitUntilWorking(on: "b.job")
        XCTAssertEqual(try status(of: "a.job"), .done("saved a.job"))
        try bench.finish("b.job")
        try await waitUntilIdle()

        XCTAssertEqual(queue.items.map(\.status), [.done("saved a.job"), .done("saved b.job")])
        XCTAssertFalse(queue.hasWaiting)
    }

    func testRunDoesNothingWithoutAWaitingItem() {
        XCTAssertFalse(run())

        XCTAssertFalse(queue.isRunning)
        XCTAssertNil(queue.folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testOnlyItemsThePredicateAcceptsAreWorkedOn() async throws {
        add("a.job", "b.job")

        let bench: Bench = bench
        queue.run(where: { $0.name == "b.job" }, work: { try await bench.work($0, $1, $2) })
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()

        XCTAssertEqual(bench.started, ["b.job"])
        XCTAssertEqual(try status(of: "a.job"), .waiting)
    }

    func testEveryRunOfOneQueueSavesIntoTheSameDatedFolderUnderTheGivenParent() async throws {
        add("a.job")
        run()
        try await waitUntilWorking(on: "a.job")
        try bench.finish("a.job")
        try await waitUntilIdle()
        add("b.job")
        run()
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()

        let folder = try XCTUnwrap(queue.folder)
        XCTAssertEqual(bench.folders, [folder, folder])
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, output.standardizedFileURL)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Toolbox Test Jobs "))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [folder.lastPathComponent])
    }

    func testProgressShowsWhileAnItemIsWorkedOnAndALateReportCannotUndoItsResult() async throws {
        add("a.job")
        run()
        try await waitUntilWorking(on: "a.job")

        try bench.report(0.4, for: "a.job")
        try await waitUntil("the progress shows") { try self.status(of: "a.job") == .working(0.4) }
        try bench.finish("a.job")
        try await waitUntilIdle()
        try bench.report(0.9, for: "a.job")
        try await settle("a late report would land on a later main-actor turn")

        XCTAssertEqual(try status(of: "a.job"), .done("saved a.job"))
    }

    func testAnItemWhoseWorkFailsShowsWhyAndTheRunGoesOn() async throws {
        add("a.job", "b.job")
        run()
        try await waitUntilWorking(on: "a.job")

        try bench.fail("a.job", with: JobError())
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()

        XCTAssertEqual(queue.items.map(\.status), [.failed("The job broke."), .done("saved b.job")])
    }

    func testCancelPutsTheItemInHandBackToWaitingAndStartsNoOther() async throws {
        add("a.job", "b.job")
        run()
        try await waitUntilWorking(on: "a.job")

        queue.cancel()
        try bench.fail("a.job", with: CancellationError())
        try await waitUntilIdle()

        XCTAssertEqual(queue.items.map(\.status), [.waiting, .waiting])
        XCTAssertEqual(bench.started, ["a.job"])
    }

    func testAnItemThatFinishesDespiteTheCancelKeepsItsResult() async throws {
        add("a.job", "b.job")
        run()
        try await waitUntilWorking(on: "a.job")

        queue.cancel()
        try bench.finish("a.job")
        try await waitUntilIdle()

        XCTAssertEqual(queue.items.map(\.status), [.done("saved a.job"), .waiting])
    }

    func testTheNextRunRetriesFailedItemsAlongsideAWaitingOne() async throws {
        add("a.job")
        run()
        try await waitUntilWorking(on: "a.job")
        try bench.fail("a.job", with: JobError())
        try await waitUntilIdle()

        XCTAssertFalse(run(), "a queue with only failed items has nothing waiting")
        add("b.job")
        XCTAssertTrue(run())

        XCTAssertEqual(try status(of: "a.job"), .waiting)
        try await waitUntilWorking(on: "a.job")
        try bench.finish("a.job")
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()
        XCTAssertEqual(queue.items.map(\.status), [.done("saved a.job"), .done("saved b.job")])
        XCTAssertEqual(bench.started, ["a.job", "a.job", "b.job"])
    }

    func testARunToldNotToRetryLeavesFailedItemsAlone() async throws {
        add("a.job")
        run()
        try await waitUntilWorking(on: "a.job")
        try bench.fail("a.job", with: JobError())
        try await waitUntilIdle()
        add("b.job")

        run(retryingFailed: false)
        try await waitUntilWorking(on: "b.job")
        try bench.finish("b.job")
        try await waitUntilIdle()

        XCTAssertEqual(queue.items.map(\.status), [.failed("The job broke."), .done("saved b.job")])
    }

    // MARK: Clearing

    func testClearEmptiesTheQueueAndForgetsTheFolderAndNotice() async throws {
        add("a.job", "notes.txt")
        run()
        try await waitUntilWorking(on: "a.job")
        try bench.finish("a.job")
        try await waitUntilIdle()

        queue.clear()

        XCTAssertFalse(queue.hasItems)
        XCTAssertNil(queue.folder)
        XCTAssertNil(queue.notice)
    }

    func testClearDuringARunLetsANewRunFinishOnItsOwn() async throws {
        add("old.job", "old 2.job")
        run()
        try await waitUntilWorking(on: "old.job")
        let firstFolder = try XCTUnwrap(queue.folder)

        queue.clear()
        XCTAssertFalse(queue.isRunning)
        add("new.job")
        XCTAssertTrue(run())
        try await waitUntilWorking(on: "new.job")
        try bench.report(0.7, for: "old.job")
        try bench.finish("old.job")
        try await settle("the old run would move on to its next item, or end the new run, on a later main-actor turn")

        XCTAssertTrue(queue.isRunning, "the old run finishing must not end the new one")
        XCTAssertEqual(queue.items.map(\.name), ["new.job"])
        XCTAssertEqual(try status(of: "new.job"), .working(0))
        XCTAssertEqual(bench.started, ["old.job", "new.job"], "the old run must not start its next item")
        XCTAssertNotEqual(queue.folder, firstFolder)
        try bench.report(0.5, for: "new.job")
        try await waitUntil("the new run's progress still shows") { try self.status(of: "new.job") == .working(0.5) }
        try bench.finish("new.job")
        try await waitUntilIdle()
        XCTAssertEqual(queue.items.map(\.status), [.done("saved new.job")])
    }

    func testALateFailureFromAClearedRunTouchesNothing() async throws {
        add("same.job")
        run()
        try await waitUntilWorking(on: "same.job")

        queue.clear()
        try bench.fail("same.job", with: JobError())
        add("same.job")
        try await settle("the old failure would land on a later main-actor turn")

        XCTAssertEqual(queue.items.map(\.status), [.waiting])
        XCTAssertFalse(queue.isRunning)
        XCTAssertNil(queue.notice)
    }

    // MARK: Output folder

    func testAnOutputFolderThatCannotBeMadeIsReportedAndForgottenOnceARunSucceeds() async throws {
        let blocked = dir.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        queue = makeQueue(outputParent: blocked)
        add("a.job")

        XCTAssertFalse(run())

        XCTAssertEqual(queue.notice?.hasPrefix("Couldn't create the output folder in “blocked”."), true, queue.notice ?? "no notice")
        XCTAssertFalse(queue.isRunning)
        XCTAssertNil(queue.folder)
        XCTAssertEqual(queue.items.map(\.status), [.waiting])
        XCTAssertEqual(bench.started, [])

        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        XCTAssertTrue(run())

        XCTAssertNil(queue.notice)
        try await waitUntilWorking(on: "a.job")
        try bench.finish("a.job")
        try await waitUntilIdle()
        XCTAssertEqual(queue.folder?.deletingLastPathComponent().lastPathComponent, "blocked")
    }

    func testStartingARunKeepsANoticeAboutSkippedFiles() async throws {
        add("a.job", "notes.txt")

        run()

        XCTAssertEqual(queue.notice, "1 item(s) had no jobs and were skipped.")
        try await waitUntilWorking(on: "a.job")
        try bench.finish("a.job")
        try await waitUntilIdle()
    }
}
