import XCTest
@testable import Toolbox

@MainActor
final class VaultMatchCacheTests: XCTestCase {
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

    private func countingFinder() -> VaultMatchCache {
        VaultMatchCache { [reads] item in
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
        let finder = VaultMatchCache { [reads] item in
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

    func testAnAddOnlyReadsTheFilesThatCouldMatchIt() async throws {
        let finder = countingFinder()
        let vault = VaultLibrary.items(in: root)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("MOVIE-BYTES".utf8).write(to: outside.appendingPathComponent("new.mp4"))
        try Data("short".utf8).write(to: outside.appendingPathComponent("unique.mp4"))
        let incoming = try [XCTUnwrap(VaultLibrary.item(at: outside.appendingPathComponent("new.mp4"))),
                            XCTUnwrap(VaultLibrary.item(at: outside.appendingPathComponent("unique.mp4")))]

        let groups = await finder.matches(for: incoming, in: vault, lengths: [:])

        XCTAssertEqual(names(groups), [["a.mp4", "b.mp4", "new.mp4"]])
        XCTAssertEqual(reads.value, 4, "a file of a size nothing incoming has was read")
    }

    func testASetKeptWholeIsNeverSuggestedAgainEvenAfterARename() async throws {
        let store = try VaultDistinctPairs(privateFolder: root.appendingPathComponent(".toolbox"))
        defer { store.close() }
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)
        let found = await finder.groups(in: items, lengths: [:])
        let pair = try XCTUnwrap(found?.first)

        try store.keepTogether(try await finder.digests(of: pair.copies))
        let old = try XCTUnwrap(items.first { $0.name == "b.mp4" })
        let target = root.appendingPathComponent("renamed.mp4")
        try FileManager.default.moveItem(at: old.url, to: target)
        let renamed = try XCTUnwrap(VaultLibrary.item(at: target))

        let after = await countingFinder().groups(in: items.map { $0 == old ? renamed : $0 }, lengths: [:], remembered: store)

        XCTAssertEqual(names(after), [])
        let reopened = try VaultDistinctPairs(privateFolder: root.appendingPathComponent(".toolbox"))
        defer { reopened.close() }
        XCTAssertEqual(reopened.keptTogether, store.keptTogether, "the choice was not saved")
    }

    func testAKeptPairInsideABiggerSetLeavesTheSetWhole() async throws {
        try write("MOVIE-BYTES", to: "d.mp4")
        let store = try VaultDistinctPairs(privateFolder: root.appendingPathComponent(".toolbox"))
        defer { store.close() }
        let finder = countingFinder()
        let items = VaultLibrary.items(in: root)
        let a = try XCTUnwrap(items.first { $0.name == "a.mp4" })
        let b = try XCTUnwrap(items.first { $0.name == "b.mp4" })
        try store.keepTogether(try await finder.digests(of: [a, b]))

        let groups = await finder.groups(in: items, lengths: [:], remembered: store)

        XCTAssertEqual(names(groups), [], "same bytes have one digest, so keeping a and b whole keeps d with them too")
    }
}
