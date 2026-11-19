import XCTest
@testable import Toolbox

@MainActor
final class VaultDuplicateFinderTests: XCTestCase {
    private var root: URL!
    private let reads = Locked(0)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-duplicate-finder-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("MOVIE-BYTES", to: "a.mp4")
        try write("MOVIE-BYTES", to: "b.mp4")
        try write("OTHER-BYTES", to: "c.mp4")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    private func countingFinder() -> VaultDuplicateFinder {
        VaultDuplicateFinder { [reads] item in
            reads.update { $0 += 1 }
            return try VaultMover.sha256(item.url)
        }
    }

    private func names(_ groups: [VaultDuplicates.Group]?) -> [[String]]? {
        groups?.map { $0.copies.map(\.name).sorted() }
    }

    func testIdenticalFilesAreFoundAndASecondPassReadsNoFileAgain() async throws {
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)

        let first = await finder.groups(in: items, lengths: [:])

        XCTAssertEqual(names(first), [["a.mp4", "b.mp4"]])
        XCTAssertEqual(reads.value, 3)

        let second = await finder.groups(in: items, lengths: [:])

        XCTAssertEqual(names(second), [["a.mp4", "b.mp4"]])
        XCTAssertEqual(reads.value, 3, "files already read were read again")
    }

    func testARenamedFileIsNotReadAgain() async throws {
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)
        _ = await finder.groups(in: items, lengths: [:])
        let old = try XCTUnwrap(items.first { $0.name == "b.mp4" })
        let target = root.appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: old.url, to: target)
        let renamed = VaultItem(url: target, kind: old.kind, added: old.added, bytes: old.bytes)

        finder.carry(from: old, to: renamed)
        let groups = await finder.groups(in: items.map { $0 == old ? renamed : $0 }, lengths: [:])

        XCTAssertEqual(names(groups), [["a.mp4", "renamed.mp4"]])
        XCTAssertEqual(reads.value, 3, "the renamed file was read again")
    }

    func testForgettingMeansEveryFileIsReadAfresh() async throws {
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)
        _ = await finder.groups(in: items, lengths: [:])

        finder.forget()
        let groups = await finder.groups(in: items, lengths: [:])

        XCTAssertEqual(names(groups), [["a.mp4", "b.mp4"]])
        XCTAssertEqual(reads.value, 6, "digests from before the vault locked were still used")
    }

    func testACancelledPassGivesNoAnswer() async throws {
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)

        let pass = Task { await finder.groups(in: items, lengths: [:]) }
        pass.cancel()
        let groups = await pass.value

        XCTAssertNil(groups)
    }

    func testAPassThatWasReadingWhenTheVaultLockedGivesNoAnswerAndLeavesNothingRemembered() async throws {
        let reading = Locked(false)
        let mayFinish = DispatchSemaphore(value: 0)
        let finder = VaultDuplicateFinder { [reads] item in
            reads.update { $0 += 1 }
            if !reading.value {
                reading.set(true)
                mayFinish.wait()
            }
            return try VaultMover.sha256(item.url)
        }
        let items = VaultLibrary.items(in: root)
        let pass = Task { await finder.groups(in: items, lengths: [:]) }
        try await waitUntil("the pass is reading a file") { reading.value }

        finder.forget()
        mayFinish.signal()
        let groups = await pass.value

        XCTAssertNil(groups, "duplicates found in a vault that has since locked were shown")
        let readsBefore = reads.value
        _ = await finder.groups(in: items, lengths: [:])
        XCTAssertEqual(reads.value - readsBefore, 3, "digests read across a lock were remembered")
    }
}
