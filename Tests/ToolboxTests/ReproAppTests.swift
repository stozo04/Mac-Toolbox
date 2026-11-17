import XCTest
@testable import Toolbox

final class ReproAppTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("repro-app-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor func testU1DroppingATextFileAndAVideoTogetherStillReportsTheSkippedFile() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("notes.txt"), clip = dir.appendingPathComponent("clip.mov")
        try Data("hello".utf8).write(to: notes)
        try Data().write(to: clip)
        let model = MuteVideoModel()

        for dropped in [notes, clip] { model.add([dropped]) }

        XCTAssertEqual(model.items.count, 1)
        XCTAssertNotNil(model.notice, "one drop of two files, one skipped: the user must be told")
    }

    @MainActor func testU1TheSameDropInTheOtherOrderDoesReport() throws {
        let dir = try makeTempDir(); defer { try? fm.removeItem(at: dir) }
        let notes = dir.appendingPathComponent("notes.txt"), clip = dir.appendingPathComponent("clip.mov")
        try Data("hello".utf8).write(to: notes)
        try Data().write(to: clip)
        let model = MuteVideoModel()

        for dropped in [clip, notes] { model.add([dropped]) }

        XCTAssertNotNil(model.notice)
    }

    @MainActor func testV5ClearingStorageDoesNotRunOnTheMainThread() async throws {
        let home = try makeTempDir(); defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/com.big.app")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 300_000).write(to: cache.appendingPathComponent("blob"))
        final class Seen: @unchecked Sendable { var onMain: Bool? }
        let seen = Seen()
        let model = StorageExplorerModel(hogs: SpaceHog.all(home: home),
                                         trash: { seen.onMain = Thread.isMainThread; try FileManager.default.removeItem(at: $0) },
                                         delete: { try FileManager.default.removeItem(at: $0) })
        model.measureAll()
        let deadline = Date().addingTimeInterval(10)
        while model.isMeasuring, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let caches = try XCTUnwrap(model.hogs.first { $0.id == "caches" })
        model.open(caches)
        model.toggle(try XCTUnwrap(model.result(caches)?.items.first))

        model.clearSelected()
        while seen.onMain == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(seen.onMain, false, "moving files to the Trash must not block the main thread")
    }
}
