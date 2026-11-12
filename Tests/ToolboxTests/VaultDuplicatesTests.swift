import XCTest
@testable import Toolbox

final class VaultDuplicatesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-duplicates-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testIdenticalFilesGroupWhateverTheirNames() throws {
        try write("AAAA", to: "beach.jpg")
        try write("AAAA", to: "beach copy.jpg")
        try write("AAAA", to: "IMG_0001.jpg")
        try write("BBBB", to: "same-size-other.jpg")
        try write("CC", to: "alone.jpg")

        let groups = VaultDuplicates.groups(in: VaultLibrary.items(in: root)) { try VaultMover.sha256($0.url) }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(try XCTUnwrap(groups.first).copies.map(\.name)), ["beach.jpg", "beach copy.jpg", "IMG_0001.jpg"])
        XCTAssertEqual(groups.first?.extraBytes, 8)
    }

    func testImagesAndVideosAreBothFound() throws {
        try write("PHOTO", to: "a.png")
        try write("PHOTO", to: "b.png")
        try write("MOVIE-BYTES", to: "a.mp4")
        try write("MOVIE-BYTES", to: "b.mp4")

        let groups = VaultDuplicates.groups(in: VaultLibrary.items(in: root)) { try VaultMover.sha256($0.url) }

        XCTAssertEqual(Set(groups.compactMap(\.kind)), [.image, .video])
        XCTAssertEqual(VaultDuplicates.filtered(groups, by: .videos).flatMap(\.copies).map(\.name).sorted(), ["a.mp4", "b.mp4"])
        XCTAssertEqual(VaultDuplicates.filtered(groups, by: .images).flatMap(\.copies).map(\.name).sorted(), ["a.png", "b.png"])
        XCTAssertEqual(VaultDuplicates.filtered(groups, by: .all).count, 2)
    }

    func testBiggestWasteComesFirstAndTheOldestCopyLeads() {
        let old = item("old.mp4", bytes: 100, added: 1)
        let new = item("new.mp4", bytes: 100, added: 5)
        let smallA = item("a.jpg", bytes: 10, added: 1)
        let smallB = item("b.jpg", bytes: 10, added: 2)
        let smallC = item("c.jpg", bytes: 10, added: 3)

        let groups = VaultDuplicates.groups(in: [new, smallC, old, smallA, smallB]) { Data(String($0.bytes).utf8) }

        XCTAssertEqual(groups.map { $0.copies.map(\.name) }, [["old.mp4", "new.mp4"], ["a.jpg", "b.jpg", "c.jpg"]])
    }

    func testKeepingOneLeavesTheOthersToRemove() {
        let a = item("a.jpg", bytes: 10, added: 1)
        let b = item("b.jpg", bytes: 10, added: 2)
        let c = item("c.jpg", bytes: 10, added: 3)
        let group = VaultDuplicates.Group(copies: [a, b, c])

        XCTAssertEqual(VaultDuplicates.others(than: b, in: group), [a, c])
    }

    func testUnreadableFilesAndEmptyFilesAreNeverGrouped() {
        let empty1 = item("e1.jpg", bytes: 0, added: 1)
        let empty2 = item("e2.jpg", bytes: 0, added: 2)
        let broken1 = item("x1.jpg", bytes: 5, added: 1)
        let broken2 = item("x2.jpg", bytes: 5, added: 2)

        let groups = VaultDuplicates.groups(in: [empty1, empty2, broken1, broken2]) { _ in throw CocoaError(.fileReadUnknown) }

        XCTAssertTrue(groups.isEmpty)
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    private func item(_ name: String, bytes: Int64, added: TimeInterval) -> VaultItem {
        VaultItem(url: URL(fileURLWithPath: "/vault/\(name)"), kind: VaultItem.kind(of: URL(fileURLWithPath: name)) ?? .image,
                  added: Date(timeIntervalSince1970: added), bytes: bytes)
    }
}
