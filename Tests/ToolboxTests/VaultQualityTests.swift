import AVFoundation
import XCTest
@testable import Toolbox

final class VaultQualityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vault-quality-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testResolutionIsLabelledByItsShortSide() {
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 1080, height: 1920), "1080p")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 3840, height: 2160), "4K")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 2560, height: 1440), "1440p")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 1280, height: 720), "720p")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 1024, height: 576), "576p")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 854, height: 480), "480p")
        XCTAssertEqual(VaultQuality.resolutionLabel(width: 320, height: 240), "240p")
    }

    func testTwoRealEncodesAreReadAndTheSharperOneIsHigherQuality() async throws {
        let sharp = try await VaultTestMedia.sceneVideo(at: root.appendingPathComponent("sharp.mp4"), scene: .stripes, seconds: 2,
                                                        width: 720, height: 1280, bitrate: 4_000_000, codec: .hevc)
        let soft = try await VaultTestMedia.sceneVideo(at: root.appendingPathComponent("soft.mp4"), scene: .stripes, seconds: 2,
                                                       width: 432, height: 768, bitrate: 400_000)
        let first = try await read(sharp)
        let second = try await read(soft)

        XCTAssertEqual(first.line("Resolution")?.value, "720 × 1280 · 720p")
        XCTAssertEqual(second.line("Resolution")?.value, "432 × 768 · 432p")
        XCTAssertEqual(first.line("Video codec")?.value.hasPrefix("HEVC"), true)
        XCTAssertEqual(second.line("Video codec")?.value.hasPrefix("H.264"), true)
        XCTAssertNotNil(first.line("Frame rate"))
        XCTAssertNotNil(first.line("Bitrate"))
        XCTAssertEqual(first.line("Sound")?.value, "No sound")
        let comparison = VaultQualityComparison([first, second], kind: .video)
        XCTAssertEqual(comparison.best, 0)
        XCTAssertEqual(comparison.rows.first { $0.label == "Resolution" }?.better, [0])
        XCTAssertEqual(comparison.rows.first { $0.label == "Video codec" }?.better, [], "a codec is never marked better")
        XCTAssertEqual(comparison.rows.first { $0.label == "Video codec" }?.differs, true)
    }

    func testEqualPixelsAreDecidedByBitrateThenFrameRate() {
        let base = video(pixels: 100, bitrate: 1_000_000, fps: 30)
        XCTAssertEqual(VaultQualityComparison([base, video(pixels: 100, bitrate: 2_000_000, fps: 30)], kind: .video).best, 1)
        XCTAssertEqual(VaultQualityComparison([base, video(pixels: 100, bitrate: 1_010_000, fps: 60)], kind: .video).best, 1,
                       "bitrates within 2% count as the same, so the frame rate decides")
        XCTAssertNil(VaultQualityComparison([base, video(pixels: 100, bitrate: 1_010_000, fps: 30.01)], kind: .video).best,
                     "equal on everything reads as the same quality")
        XCTAssertEqual(VaultQualityComparison([video(pixels: 50, bitrate: 9_000_000, fps: 60), base], kind: .video).best, 1,
                       "more pixels win before bitrate")
    }

    func testPhotosWithEqualPixelsAreTheSameQualityWhateverTheirSize() {
        let big = VaultQuality(lines: [.init(label: "Size", value: "9 MB")], pixels: 1200)
        let small = VaultQuality(lines: [.init(label: "Size", value: "1 MB")], pixels: 1200)
        XCTAssertNil(VaultQualityComparison([big, small], kind: .image).best)
    }

    func testRowsKeepEachCopysOrderAndShowWhatOnlySomeCopiesHave() throws {
        let first = VaultQuality(lines: [.init(label: "Resolution", value: "a"), .init(label: "Video codec", value: "H.264"),
                                         .init(label: "Bitrate", value: "1")])
        let second = VaultQuality(lines: [.init(label: "Resolution", value: "a"), .init(label: "Video codec", value: "HEVC"),
                                          .init(label: "Bit depth", value: "10-bit"), .init(label: "Bitrate", value: "1")])

        let comparison = VaultQualityComparison([first, second], kind: .video)

        XCTAssertEqual(comparison.rows.map(\.label), ["Resolution", "Video codec", "Bit depth", "Bitrate"])
        let depth = try XCTUnwrap(comparison.rows.first { $0.label == "Bit depth" })
        XCTAssertEqual(depth.values, [nil, "10-bit"])
        XCTAssertTrue(depth.differs)
        XCTAssertEqual(comparison.rows.first { $0.label == "Resolution" }?.differs, false)
    }

    func testAPhotoIsReadWithItsDimensionsAndFormat() async throws {
        let photo = try VaultTestMedia.uniquePhoto(at: root.appendingPathComponent("p.png"))
        let quality: VaultQuality? = try await read(photo)
        XCTAssertEqual(quality?.line("Dimensions")?.value, "8 × 8 · 8p")
        XCTAssertNotNil(quality?.line("Format"))
        XCTAssertNil(quality?.line("Added to vault"), "a file not in the vault has no date added")
        XCTAssertEqual(quality?.line("Name")?.value, "p.png")
    }

    private func read(_ url: URL) async throws -> VaultQuality {
        let item = try XCTUnwrap(VaultLibrary.item(at: url))
        return await VaultQuality.read(item, inVault: false)
    }

    private func video(pixels: Int, bitrate: Double, fps: Double) -> VaultQuality {
        VaultQuality(lines: [], pixels: pixels, bitrate: bitrate, frameRate: fps)
    }
}
