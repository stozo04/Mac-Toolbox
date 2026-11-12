import VaultSearch
import XCTest
@testable import Toolbox

final class VaultDetailsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-details-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testRenameKeepsTheExtensionAndTrimsSpaces() {
        let clip = item("tiktok_7468015357786148128.mp4")

        XCTAssertEqual(VaultRename.editableName(of: clip), "tiktok_7468015357786148128")
        XCTAssertEqual(VaultRename.fileName(for: "  hair routine  ", renaming: clip), .success("hair routine.mp4"))
    }

    func testRenameRefusesNamesThatWouldBreakOrHideTheFile() {
        let clip = item("a.mp4")

        XCTAssertEqual(VaultRename.fileName(for: "   ", renaming: clip), .failure(.empty))
        XCTAssertEqual(VaultRename.fileName(for: "a/b", renaming: clip), .failure(.badCharacter))
        XCTAssertEqual(VaultRename.fileName(for: "a:b", renaming: clip), .failure(.badCharacter))
        XCTAssertEqual(VaultRename.fileName(for: ".secret", renaming: clip), .failure(.startsWithDot))
        XCTAssertEqual(VaultRename.fileName(for: String(repeating: "x", count: 252), renaming: clip), .failure(.tooLong))
    }

    func testRenameRefusesATakenNameButAllowsTheSameNameAndCaseChanges() throws {
        try write("A", to: "first.mp4")
        try write("B", to: "second.mp4")
        let first = try XCTUnwrap(VaultLibrary.items(in: root).first { $0.name == "first.mp4" })

        XCTAssertEqual(VaultRename.destination(for: "second", renaming: first), .failure(.taken))
        XCTAssertEqual(VaultRename.destination(for: "first", renaming: first), .success(nil))
        let target = try VaultRename.destination(for: "First", renaming: first).get()
        XCTAssertEqual(target?.lastPathComponent, "First.mp4")
    }

    func testACaseOnlyRenameReallyChangesTheName() throws {
        try write("A", to: "clip.mp4")
        let clip = try XCTUnwrap(VaultLibrary.items(in: root).first)
        let target = try XCTUnwrap(try VaultRename.destination(for: "Clip", renaming: clip).get())

        try VaultRename.move(clip, to: target)

        XCTAssertEqual(VaultLibrary.items(in: root).map(\.name), ["Clip.mp4"])
    }

    func testTheSearchEntryFollowsARenameWithoutReembedding() async throws {
        try write("VIDEO", to: "old.mp4")
        let old = try XCTUnwrap(VaultLibrary.items(in: root).first)
        let engine = engineWithoutModel()
        let index = try VaultIndex(at: indexURL())
        try index.store(path: "old.mp4", file: VaultSearchEngine.fingerprint(old.url), segments: [
            VaultSegment(modality: .image, start: 0, end: 1, vector: vector(1)),
            VaultSegment(modality: .audio, start: 0, end: 5, vector: vector(2)),
        ])
        index.close()

        let target = root.appendingPathComponent("new.mp4")
        try VaultRename.move(old, to: target)
        try await engine.rename(old.url, to: target)
        let renamed = try XCTUnwrap(VaultLibrary.items(in: root).first)

        let coverage = try await engine.coverage(of: renamed)
        XCTAssertEqual(coverage?.segments, [.image: 1, .audio: 1])
        let oldCoverage = try await engine.coverage(of: old)
        XCTAssertNil(oldCoverage)
        engine.close()
    }

    func testAChangedFileDoesNotCountAsInSearch() async throws {
        try write("VIDEO", to: "clip.mp4")
        let clip = try XCTUnwrap(VaultLibrary.items(in: root).first)
        let index = try VaultIndex(at: indexURL())
        try index.store(path: "clip.mp4", file: VaultIndexedFile(bytes: 999, modified: 0),
                        segments: [VaultSegment(modality: .image, start: 0, end: 1, vector: vector(1))])
        index.close()
        let engine = engineWithoutModel()

        let coverage = try await engine.coverage(of: clip)

        XCTAssertNil(coverage)
        engine.close()
    }

    func testRenamingOverAStaleEntryReplacesIt() throws {
        let index = try VaultIndex(at: indexURL())
        try index.store(path: "a.mp4", file: VaultIndexedFile(bytes: 1, modified: 1),
                        segments: [VaultSegment(modality: .image, start: 0, end: 1, vector: vector(1))])
        try index.store(path: "b.mp4", file: VaultIndexedFile(bytes: 2, modified: 2),
                        segments: [VaultSegment(modality: .audio, start: 0, end: 1, vector: vector(2))])

        try index.rename("a.mp4", to: "b.mp4")

        XCTAssertEqual(try index.files().keys.sorted(), ["b.mp4"])
        XCTAssertEqual(try index.coverage(of: "b.mp4"), VaultIndexCoverage(file: VaultIndexedFile(bytes: 1, modified: 1), segments: [.image: 1]))
        XCTAssertEqual(try index.vectors().paths, ["b.mp4"])
    }

    func testThumbnailAndPlayableRecordsFollowARename() async throws {
        let privateFolder = root.appendingPathComponent(VaultLibrary.privateFolderName)
        let old = item("old.mp4", bytes: 10)
        let new = item("new.mp4", bytes: 10)
        let thumbnails = VaultThumbnails(vaultRoot: root, requiresMountedVolume: false)
        let thumbs = privateFolder.appendingPathComponent("thumbs")
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: thumbs.appendingPathComponent(VaultThumbnails.key(for: old) + ".jpg"))
        let copy = VaultPlayable.copyURL(for: old, privateFolder: privateFolder)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mov".utf8).write(to: copy)

        await thumbnails.carryOver(from: old, to: new)
        VaultPlayable.carryOver(from: old, to: new, privateFolder: privateFolder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbs.appendingPathComponent(VaultThumbnails.key(for: new) + ".jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: VaultPlayable.copyURL(for: new, privateFolder: privateFolder).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testVideoDetailsShowLengthResolutionAndSound() async throws {
        let url = try await VaultTestMedia.video(at: root.appendingPathComponent("clip.mov"), seconds: 2)
        let clip = try XCTUnwrap(VaultLibrary.items(in: root).first)

        let details = await VaultFileDetails.load(clip, playable: url)
        let values = Dictionary(uniqueKeysWithValues: details.lines.map { ($0.label, $0.value) })

        XCTAssertEqual(values["Length"], "0:02")
        XCTAssertEqual(values["Resolution"], "256 × 256")
        XCTAssertEqual(values["Sound"], "No sound")
        XCTAssertNotNil(values["Video codec"])
        XCTAssertNotNil(values["Added to vault"])
    }

    func testPhotoDetailsShowDimensions() async throws {
        let url = root.appendingPathComponent("photo.png")
        let image = try XCTUnwrap(CGImage.solid(width: 40, height: 30))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = try XCTUnwrap(VaultLibrary.items(in: root).first)

        let details = await VaultFileDetails.load(photo, playable: url)

        XCTAssertEqual(details.lines.first { $0.label == "Dimensions" }?.value, "40 × 30")
    }

    private func engineWithoutModel() -> VaultSearchEngine {
        let placeholder = EmbeddingModel.Located(text: root.appendingPathComponent("t.gguf"), media: root.appendingPathComponent("m.gguf"))
        return VaultSearchEngine(root: root, model: placeholder, requiresMountedVolume: false)
    }

    private func indexURL() throws -> URL {
        let folder = root.appendingPathComponent(VaultLibrary.privateFolderName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(VaultIndex.fileName)
    }

    private func vector(_ value: Float) -> [Float] { Array(repeating: value, count: LlamaEmbedder.dimension) }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }

    private func item(_ name: String, bytes: Int64 = 1) -> VaultItem {
        VaultItem(url: root.appendingPathComponent(name), kind: VaultItem.kind(of: URL(fileURLWithPath: name)) ?? .image,
                  added: Date(timeIntervalSince1970: 0), bytes: bytes)
    }
}

private extension CGImage {
    static func solid(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }
}
