import AVFoundation
import XCTest
@testable import Toolbox

final class ResizeVideoTests: XCTestCase {
    private func layout(_ src: CGSize, _ w: Int, _ h: Int, aspect: Bool = true, fit: ResizeFit = .blackBars) -> ResizePlan.Layout {
        ResizePlan.layout(source: src, settings: ResizeSettings(width: w, height: h, keepAspect: aspect, fit: fit))
    }

    func testOddSizesRoundDownToEven() {
        XCTAssertEqual(layout(CGSize(width: 100, height: 100), 641, 361, aspect: false).renderSize, CGSize(width: 640, height: 360))
    }

    func testBlackBarsCentresPictureInExactFrame() {
        // 16:9 source into a vertical frame: scaled to the width, bars above and below.
        let l = layout(CGSize(width: 1920, height: 1080), 1080, 1920)
        XCTAssertEqual(l.renderSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(l.scaleX, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(l.offset, CGPoint(x: 0, y: (1920 - 607.5) / 2).rounded)
    }

    func testCropFillsFrameAndCentresOverflow() {
        let l = layout(CGSize(width: 1920, height: 1080), 1080, 1920, fit: .crop)
        XCTAssertEqual(l.renderSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(l.scaleX, 1920.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(l.offset.y, 0)
        XCTAssertLessThan(l.offset.x, 0)
    }

    func testFitWithinShrinksTheFrameToThePicture() {
        let l = layout(CGSize(width: 1920, height: 1080), 1280, 1280, fit: .within)
        XCTAssertEqual(l.renderSize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(l.offset, .zero)
    }

    func testStretchIgnoresAspect() {
        let l = layout(CGSize(width: 1920, height: 1080), 1000, 1000, aspect: false)
        XCTAssertEqual(l.renderSize, CGSize(width: 1000, height: 1000))
        XCTAssertNotEqual(l.scaleX, l.scaleY)
    }

    @MainActor func testPresetsAndFieldsStayInSync() {
        let m = ResizeVideoModel()
        m.preset = SizePreset.all.first { $0.name == "720p" }!
        XCTAssertEqual([m.width, m.height], [1280, 720])
        m.width = 1000
        XCTAssertEqual(m.preset, .custom)
        m.width = 1280
        XCTAssertEqual(m.preset.name, "720p")
        // Swapping 1080 x 1920 -> 1920 x 1080 must not be disturbed by the in-between 1080 x 1080 (Square).
        m.preset = SizePreset.all.first { $0.name == "Vertical" }!
        m.swapSize()
        XCTAssertEqual([m.width, m.height], [1920, 1080])
        XCTAssertEqual(m.preset.name, "1080p")
    }

    func testResizesToExactSizeInBothCodecs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resize-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 640, height: 360), seconds: 1)

        for (codec, fourCC) in [(ResizeCodec.h264, "avc1"), (.hevc, "hvc1")] {
            let out = try await VideoResizer.resize(source: video, settings: ResizeSettings(width: 361, height: 641, fit: .crop, codec: codec),
                                                    into: dir) { _ in }
            let asset = AVURLAsset(url: out)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize)
            let formats = try await track.load(.formatDescriptions)
            let duration = try await asset.load(.duration).seconds
            XCTAssertEqual(size, CGSize(width: 360, height: 640), "\(codec)")
            XCTAssertEqual(fourCharString(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first))), fourCC)
            XCTAssertEqual(duration, 1, accuracy: 0.1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testBlackBarsAreActuallyBlackAndPictureIsCentred() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("resize-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 640, height: 360), seconds: 2)

        // 16:9 into a square: bars above and below.
        let out = try await VideoResizer.resize(source: video, settings: ResizeSettings(width: 360, height: 360, fit: .blackBars), into: dir) { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        let image = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        XCTAssertEqual([image.width, image.height], [360, 360])
        XCTAssertLessThan(luma(image, x: 180, y: 10), 12, "top bar should be black")
        XCTAssertLessThan(luma(image, x: 180, y: 350), 12, "bottom bar should be black")
        XCTAssertGreaterThan(luma(image, x: 180, y: 180), 60, "picture should fill the middle")
    }

    private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Int(px[0])
    }

    private func fourCharString(_ n: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((n >> $0) & 0xFF) }, encoding: .ascii) ?? ""
    }

    private func makeVideo(at url: URL, size: CGSize, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let b = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(i * 2 % 256), CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

private extension CGPoint {
    var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}
