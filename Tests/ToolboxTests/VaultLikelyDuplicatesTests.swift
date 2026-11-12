import XCTest
@testable import Toolbox

final class VaultLikelyDuplicatesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-likely-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testTheSameTikTokSavedUnderTwoNamesIsALikelyDuplicate() {
        let byID = item("tiktok_7468015357786148128.mp4", bytes: 9_100_000, added: 1)
        let byCaption = item("Here is my hair routine 😛 but pls lmk if you guys have any recommendat... [7468015357786148128].mp4",
                             bytes: 8_700_000, added: 2)
        let other = item("tiktok_7468015357786140000.mp4", bytes: 9_100_001, added: 3)

        let groups = VaultDuplicates.groups(in: [byCaption, other, byID], digest: digestOfName,
                                            durations: [byID: 258.1, byCaption: 258.0, other: 258.0])

        XCTAssertEqual(groups.map { $0.copies.map(\.name) }, [[byID.name, byCaption.name]])
        XCTAssertEqual(groups.first?.match, .likely)
        XCTAssertEqual(groups.first?.extraBytes, 8_700_000)
    }

    func testPostIDsAreReadFromDownloadNamesButTimestampsAreNot() {
        XCTAssertEqual(VaultDuplicates.postID(in: "tiktok_7468015357786148128.mp4"), "7468015357786148128")
        XCTAssertEqual(VaultDuplicates.postID(in: "cheeky transition [7520655440724757782].mp4"), "7520655440724757782")
        XCTAssertEqual(VaultDuplicates.postID(in: "Never Gonna Give You Up [dQw4w9WgXcQ].webm"), "dQw4w9WgXcQ")
        XCTAssertNil(VaultDuplicates.postID(in: "ssstik.io_@evvrythingrosie_1788979705864.mp4"))
        XCTAssertNil(VaultDuplicates.postID(in: "IMG_0001.mov"))
    }

    func testTheSameIDWithClearlyDifferentLengthsStaysApart() {
        let first = item("a [7468015357786148128].mp4", bytes: 10, added: 1)
        let second = item("b [7468015357786148128].mp4", bytes: 20, added: 2)

        let groups = VaultDuplicates.groups(in: [first, second], digest: digestOfName, durations: [first: 30, second: 61])

        XCTAssertTrue(groups.isEmpty)
    }

    func testPhotosNeverGroupByIDAlone() {
        let slide1 = item("post [7468015357786148128] 1.jpg", bytes: 10, added: 1)
        let slide2 = item("post [7468015357786148128] 2.jpg", bytes: 20, added: 2)

        XCTAssertTrue(VaultDuplicates.groups(in: [slide1, slide2], digest: digestOfName).isEmpty)
    }

    func testVideosThatLookTheSameGroupEvenWithUnrelatedNames() throws {
        let download = item("ssstik.io_@evvrythingrosie_1788979705864.mp4", bytes: 5_000_000, added: 1)
        let saved = item("katseye with @Umberto Giannini [7681367781455056150].mp4", bytes: 6_000_000, added: 2)
        let sameLengthOther = item("ssstik.io_@evvrythingrosie_1772133956376.mp4", bytes: 5_500_000, added: 3)
        let lookA = try look(.stripes), lookB = try look(.rings)

        let groups = VaultDuplicates.groups(in: [download, saved, sameLengthOther], digest: digestOfName,
                                            durations: [download: 14.0, saved: 14.6, sameLengthOther: 14.2],
                                            looks: [download: lookA, saved: lookA, sameLengthOther: lookB])

        XCTAssertEqual(groups.map { $0.copies.map(\.name) }, [[download.name, saved.name]])
        XCTAssertEqual(groups.first?.match, .likely)
    }

    func testLookalikeVideosOfDifferentLengthsStayApart() throws {
        let short = item("a.mp4", bytes: 10, added: 1)
        let long = item("b.mp4", bytes: 20, added: 2)
        let same = try look(.stripes)

        let groups = VaultDuplicates.groups(in: [short, long], digest: digestOfName, durations: [short: 14, long: 40],
                                            looks: [short: same, long: same])

        XCTAssertTrue(groups.isEmpty)
    }

    func testExactCopiesStayExactAndComeFirst() throws {
        try write("SAME", to: "a.mp4")
        try write("SAME", to: "b.mp4")
        try write("first", to: "x [7468015357786148128].mp4")
        try write("second!", to: "y [7468015357786148128].mp4")

        let groups = VaultDuplicates.groups(in: VaultLibrary.items(in: root)) { try VaultMover.sha256($0.url) }

        XCTAssertEqual(groups.map(\.match), [.exact, .likely])
        XCTAssertEqual(Set(groups[0].copies.map(\.name)), ["a.mp4", "b.mp4"])
    }

    func testAnExactPairAndALookalikeBecomeOneLikelyGroup() throws {
        let a = item("a.mp4", bytes: 100, added: 1)
        let b = item("b.mp4", bytes: 100, added: 2)
        let c = item("c.mp4", bytes: 70, added: 3)
        let same = try look(.stripes)

        let groups = VaultDuplicates.groups(in: [a, b, c], digest: { _ in Data("same".utf8) },
                                            durations: [a: 9, b: 9, c: 9.2], looks: [a: same, c: same])

        XCTAssertEqual(groups.map { $0.copies.map(\.name) }, [["a.mp4", "b.mp4", "c.mp4"]])
        XCTAssertEqual(groups.first?.match, .likely)
    }

    func testOnlyVideosNearAnotherVideosLengthAreLookedAt() {
        let photo = item("p.jpg", bytes: 10, added: 1)
        let a = item("a.mp4", bytes: 10, added: 1)
        let b = item("b.mp4", bytes: 10, added: 2)
        let loner = item("c.mp4", bytes: 10, added: 3)
        let unknown = item("d.mp4", bytes: 10, added: 4)

        let candidates = VaultDuplicates.lookCandidates(in: [photo, a, b, loner, unknown], durations: [a: 20, b: 21, loner: 90])

        XCTAssertEqual(Set(candidates.map(\.name)), ["p.jpg", "a.mp4", "b.mp4"])
    }

    func testAPhotoResemblesASmallerRecompressedCopyButNotAnotherPhoto() throws {
        let original = try VaultTestMedia.sceneImage(.stripes, side: 640)
        let smaller = try VaultTestMedia.sceneImage(.stripes, side: 200)
        let other = try VaultTestMedia.sceneImage(.rings, side: 640)
        let lookOf = { (image: CGImage) in VaultLook(frames: [VaultLookReader.hash(image)], aspect: 1) }

        XCTAssertTrue(lookOf(original).resembles(lookOf(smaller)))
        XCTAssertFalse(lookOf(original).resembles(lookOf(other)))
    }

    func testPhotosNeedACloserMatchThanVideos() {
        let frame: VaultLook.FrameHash = [0x5555_5555_5555_5555, 0x3333_3333_3333_3333, 0x0F0F_0F0F_0F0F_0F0F, 0x00FF_00FF_00FF_00FF]
        let nudged: VaultLook.FrameHash = [frame[0] ^ 0x3FFF_FFFF, frame[1], frame[2], frame[3]]
        XCTAssertEqual(VaultLook.distance(frame, nudged), 30)

        let photo = VaultLook(frames: [frame], aspect: 1), nudgedPhoto = VaultLook(frames: [nudged], aspect: 1)
        let video = VaultLook(frames: Array(repeating: frame, count: 5), aspect: 1)
        let nudgedVideo = VaultLook(frames: Array(repeating: nudged, count: 5), aspect: 1)

        XCTAssertFalse(photo.resembles(nudgedPhoto))
        XCTAssertTrue(video.resembles(nudgedVideo))
    }

    func testFlatFramesNeverCountAsTheSameLook() {
        let flat = VaultLook(frames: [[0, 0, 0, 0]], aspect: 1)

        XCTAssertFalse(flat.resembles(flat))
    }

    func testTwoEncodesOfOneVideoReadAsTheSameLookAndAnotherVideoDoesNot() async throws {
        let high = try await VaultTestMedia.sceneVideo(at: root.appendingPathComponent("high.mp4"), scene: .stripes, seconds: 5,
                                                       side: 320, bitrate: 2_000_000)
        let low = try await VaultTestMedia.sceneVideo(at: root.appendingPathComponent("low.mp4"), scene: .stripes, seconds: 5,
                                                      side: 192, bitrate: 150_000)
        let other = try await VaultTestMedia.sceneVideo(at: root.appendingPathComponent("other.mp4"), scene: .rings, seconds: 5,
                                                        side: 320, bitrate: 2_000_000)
        let items = VaultLibrary.items(in: root)
        let durations = await VaultBrowse.durations(of: items)
        let looks = await VaultLookReader.looks(of: items, durations: durations)
        let named = Dictionary(uniqueKeysWithValues: looks.map { ($0.key.name, $0.value) })

        XCTAssertNotEqual(try Data(contentsOf: high), try Data(contentsOf: low))
        XCTAssertEqual(named["high.mp4"]?.frames.count, 3)
        XCTAssertTrue(try XCTUnwrap(named["high.mp4"]).resembles(try XCTUnwrap(named["low.mp4"])))
        XCTAssertFalse(try XCTUnwrap(named["high.mp4"]).resembles(try XCTUnwrap(named["other.mp4"])))

        let groups = VaultDuplicates.groups(in: items, digest: { try VaultMover.sha256($0.url) }, durations: durations, looks: looks)
        XCTAssertEqual(groups.map { Set($0.copies.map(\.name)) }, [["high.mp4", "low.mp4"]])
        XCTAssertEqual(groups.first?.match, .likely)
    }

    func testSampleTimesStayInsideShortVideos() {
        XCTAssertEqual(VaultLookReader.sampleSeconds(forDuration: 30), [1, 2.5, 4, 6, 8])
        XCTAssertEqual(VaultLookReader.sampleSeconds(forDuration: 3), [1, 2.5])
        XCTAssertEqual(VaultLookReader.sampleSeconds(forDuration: 0.6), [0.3])
    }

    private func look(_ scene: VaultTestMedia.Scene) throws -> VaultLook {
        VaultLook(frames: [VaultLookReader.hash(try VaultTestMedia.sceneImage(scene, side: 256))], aspect: 9.0 / 16.0)
    }

    private func digestOfName(_ item: VaultItem) throws -> Data { Data(item.name.utf8) }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    private func item(_ name: String, bytes: Int64, added: TimeInterval) -> VaultItem {
        VaultItem(url: URL(fileURLWithPath: "/vault/\(name)"), kind: VaultItem.kind(of: URL(fileURLWithPath: name)) ?? .image,
                  added: Date(timeIntervalSince1970: added), bytes: bytes)
    }
}
