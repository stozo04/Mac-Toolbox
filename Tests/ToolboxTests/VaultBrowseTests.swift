import XCTest
@testable import Toolbox

final class VaultBrowseTests: XCTestCase {
    private let photo = VaultBrowseTests.item("photo.jpg", .image)
    private let short = VaultBrowseTests.item("short.mp4", .video)
    private let long = VaultBrowseTests.item("long.mp4", .video)
    private let middle = VaultBrowseTests.item("middle.mp4", .video)
    private let unread = VaultBrowseTests.item("unread.mp4", .video)

    private var lengths: [VaultItem: Double] { [short: 4, long: 600, middle: 65] }

    func testFilterShowsOnlyTheChosenKind() {
        let items = [photo, short, long]
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .all, order: .newest, durations: lengths), items)
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .images, order: .newest, durations: lengths), [photo])
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .videos, order: .newest, durations: lengths), [short, long])
    }

    func testEachTabCountsItsOwnKind() {
        let items = [photo, short, long, middle]
        XCTAssertEqual(VaultFilter.all.tabTitle(in: items), "All (4)")
        XCTAssertEqual(VaultFilter.images.tabTitle(in: items), "Images (1)")
        XCTAssertEqual(VaultFilter.videos.tabTitle(in: items), "Videos (3)")
        XCTAssertTrue(VaultFilter.videos.summary(of: items).hasPrefix("3 videos, "))
        XCTAssertTrue(VaultFilter.images.summary(of: items).hasPrefix("1 image, "))
        XCTAssertTrue(VaultFilter.all.summary(of: []).hasPrefix("0 items, "))
    }

    func testVideosSortByLengthBothWaysWithUnreadLengthsLast() {
        let items = [unread, middle, photo, long, short]
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .videos, order: .shortest, durations: lengths), [short, middle, long, unread])
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .videos, order: .longest, durations: lengths), [long, middle, short, unread])
    }

    func testEqualLengthsKeepTheirOrder() {
        let twin = VaultBrowseTests.item("twin.mp4", .video)
        let durations = [short: 4.0, twin: 4.0]
        XCTAssertEqual(VaultBrowse.arranged([twin, short], filter: .videos, order: .shortest, durations: durations), [twin, short])
    }

    func testLengthSortOnlyAppliesToTheVideosFilter() {
        let items = [long, photo, short]
        XCTAssertEqual(VaultBrowse.arranged(items, filter: .all, order: .shortest, durations: lengths), items)
    }

    func testTileBadgeShowsTheVideoLength() {
        XCTAssertEqual(VaultBrowse.lengthLabel(for: middle, durations: lengths), "1:05")
        XCTAssertEqual(VaultBrowse.lengthLabel(for: long, durations: lengths), "10:00")
        XCTAssertNil(VaultBrowse.lengthLabel(for: unread, durations: lengths))
        XCTAssertNil(VaultBrowse.lengthLabel(for: photo, durations: [photo: 3]))
    }

    func testLengthsAreReadFromTheVideoFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vault-browse-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try await VaultTestMedia.video(at: folder.appendingPathComponent("clip.mov"), seconds: 3)
        let broken = folder.appendingPathComponent("broken.mp4")
        try Data("not a video".utf8).write(to: broken)
        let items = VaultLibrary.items(in: folder)

        let found = await VaultBrowse.durations(of: items)

        let clipItem = try XCTUnwrap(items.first { $0.url.lastPathComponent == clip.lastPathComponent })
        XCTAssertEqual(try XCTUnwrap(found[clipItem]), 3, accuracy: 0.2)
        XCTAssertEqual(found.count, 1)
    }

    private static func item(_ name: String, _ kind: VaultItem.Kind) -> VaultItem {
        VaultItem(url: URL(fileURLWithPath: "/vault/\(name)"), kind: kind, added: Date(timeIntervalSince1970: 0), bytes: 1)
    }
}
