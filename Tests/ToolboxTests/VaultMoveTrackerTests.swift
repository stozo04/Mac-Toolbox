import XCTest
@testable import Toolbox

final class VaultMoveTrackerTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-move-tracker-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func file(_ name: String, exists: Bool = true) throws -> URL {
        let url = folder.appendingPathComponent(name)
        if exists { try Data("x".utf8).write(to: url) }
        return url
    }

    func testAMoveCountsEachFileItSettlesAndEndsWithNothingLeft() throws {
        let files = [try file("a.mov"), try file("b.mov")]
        var moves = VaultMoveTracker()

        let id = moves.begin(files)

        XCTAssertTrue(moves.isCurrent(id))
        XCTAssertEqual(moves.progress, VaultModel.MoveProgress(done: 0, total: 2))
        XCTAssertEqual(moves.stillToMove, files)

        moves.settled(try XCTUnwrap(files.first))

        XCTAssertEqual(moves.progress, VaultModel.MoveProgress(done: 1, total: 2))
        XCTAssertEqual(moves.stillToMove, Array(files.dropFirst()))

        moves.task = Task {}
        XCTAssertTrue(moves.isRunning)
        moves.end()

        XCTAssertFalse(moves.isRunning)
        XCTAssertFalse(moves.isCurrent(id), "a move that ended could still show its files in the library")
        XCTAssertNil(moves.progress)
        XCTAssertEqual(moves.stillToMove, [])
    }

    func testANewMoveIsNotTheOneBefore() throws {
        var moves = VaultMoveTracker()
        let earlier = moves.begin([try file("a.mov")])
        moves.end()

        let later = moves.begin([try file("b.mov")])

        XCTAssertFalse(moves.isCurrent(earlier))
        XCTAssertTrue(moves.isCurrent(later))
    }

    func testAnOutsideCloseSaysWhichFilesWereKeptAndWhichHadAlreadyLeft() throws {
        let kept = try file("kept.mov")
        let alreadyMoved = try file("moved.mov", exists: false)
        var moves = VaultMoveTracker()
        _ = moves.begin([kept, alreadyMoved])

        let close = moves.closedFromOutside()

        XCTAssertEqual(close.stillToMove, 2)
        XCTAssertEqual(close.unconfirmed, 1)
        XCTAssertEqual(close.notice, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 1))
        XCTAssertEqual(close.failures.map(\.source), [kept, alreadyMoved])
        XCTAssertEqual(close.failures.map(\.reason), [VaultMoveError.vaultNotOpen.localizedDescription, VaultNotices.finishedAsVaultClosed])
    }

    func testAnOutsideCloseWithNoMoveRunningMentionsNoFiles() {
        var moves = VaultMoveTracker()

        let close = moves.closedFromOutside()

        XCTAssertTrue(close.failures.isEmpty)
        XCTAssertEqual(close.notice, VaultNotices.closedFromOutside(duringImport: false, unconfirmed: 0))
    }

    func testAFileThatFinishesAfterTheCloseIsCorrectedEvenThoughTheMoveHasEnded() throws {
        let first = try file("first.mov")
        let second = try file("second.mov")
        var moves = VaultMoveTracker()
        _ = moves.begin([first, second])
        let close = moves.closedFromOutside()
        moves.end()
        try FileManager.default.removeItem(at: second)

        let correction = try XCTUnwrap(moves.correction(for: second, among: close.failures))

        XCTAssertEqual(correction.listed, 1)
        XCTAssertEqual(correction.failure.reason, VaultNotices.finishedAsVaultClosed)
        XCTAssertEqual(correction.failure.source, second)
        XCTAssertEqual(correction.noticeBefore, close.notice)
        XCTAssertEqual(correction.notice, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 1))

        var corrected = close.failures
        corrected[correction.listed] = correction.failure
        try FileManager.default.removeItem(at: first)
        let next = try XCTUnwrap(moves.correction(for: first, among: corrected))

        XCTAssertEqual(next.noticeBefore, correction.notice, "the second correction started from a stale count")
        XCTAssertEqual(next.notice, VaultNotices.closedFromOutside(duringImport: true, unconfirmed: 2))
        corrected[next.listed] = next.failure
        XCTAssertNil(moves.correction(for: first, among: corrected), "a file already corrected was counted twice")
    }

    func testNothingIsCorrectedForAFileStillOutsideOrWithoutAnOutsideClose() throws {
        let stillOutside = try file("outside.mov")
        let gone = try file("gone.mov", exists: false)
        let listedAsKept = [stillOutside, gone].map {
            VaultMoveFailure(name: $0.lastPathComponent, reason: VaultMoveError.vaultNotOpen.localizedDescription, source: $0)
        }
        var moves = VaultMoveTracker()

        XCTAssertNil(moves.correction(for: gone, among: listedAsKept), "a correction was made though the vault was never closed from outside")

        _ = moves.begin([stillOutside])
        _ = moves.closedFromOutside()

        XCTAssertNil(moves.correction(for: stillOutside, among: listedAsKept), "a file still where it was is reported as moved")
    }
}
