import XCTest
@testable import Toolbox

final class DriveSenderTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DriveSenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name)
        try Data("video".utf8).write(to: url)
        return url
    }

    func testCopiesFilesAndKeepsOriginals() throws {
        let a = try makeFile("a.mp4"), b = try makeFile("b.mp4")
        let root = base.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let dest = root.appendingPathComponent("x/y/verified")

        let result = try DriveSender.send([a, b], to: dest, root: root)

        XCTAssertEqual(result, DriveSender.Result(copied: 2, skipped: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }

    func testSkipsExistingAndMissingFilesWithoutOverwriting() throws {
        let a = try makeFile("a.mp4")
        let root = base.appendingPathComponent("drive")
        let dest = root.appendingPathComponent("verified")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dest.appendingPathComponent("a.mp4"))
        let gone = base.appendingPathComponent("gone.mp4")

        let result = try DriveSender.send([a, gone], to: dest, root: root)

        XCTAssertEqual(result, DriveSender.Result(copied: 0, skipped: 2))
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.mp4")), Data("old".utf8))
    }

    func testThrowsWhenDriveIsNotMounted() throws {
        let a = try makeFile("a.mp4")
        let root = base.appendingPathComponent("no-drive")
        XCTAssertThrowsError(try DriveSender.send([a], to: root.appendingPathComponent("verified"), root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
