import AVFoundation
import ImageIO
import XCTest
@testable import Toolbox

final class VideoToGifTests: XCTestCase {
    func testFrameTimesCoverRangeAtFps() {
        let t = GifPlan.frameTimes(start: 2, length: 1, fps: 10)
        XCTAssertEqual(t.count, 10)
        XCTAssertEqual(t.first, 2)
        XCTAssertEqual(t.last!, 2.9, accuracy: 1e-9)
        XCTAssertEqual(GifPlan.frameTimes(start: 0, length: 0.01, fps: 10).count, 1)
    }

    func testDelaysAreWholeHundredthsAndKeepAverageSpeed() {
        for fps in GifSettings.frameRates {
            let d = GifPlan.delays(count: fps * 4, fps: fps)
            XCTAssertEqual(d.reduce(0, +), 4, accuracy: 1e-9, "\(fps) fps drifted")
            XCTAssertTrue(d.allSatisfy { $0 >= 0.04 && abs($0 * 100 - ($0 * 100).rounded()) < 1e-9 })
        }
    }

    func testOutputSizeNeverEnlarges() {
        XCTAssertEqual(GifPlan.outputSize(source: CGSize(width: 1920, height: 1080), maxWidth: 480), CGSize(width: 480, height: 270))
        XCTAssertEqual(GifPlan.outputSize(source: CGSize(width: 300, height: 200), maxWidth: 480), CGSize(width: 300, height: 200))
        XCTAssertEqual(GifPlan.outputSize(source: CGSize(width: 1920, height: 1080), maxWidth: nil), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(GifPlan.outputSize(source: CGSize(width: -1080, height: 1920), maxWidth: 320), CGSize(width: 320, height: 569))
    }

    func testRangeClampsToVideo() {
        XCTAssertEqual(GifPlan.range(duration: 10, part: nil)?.length, 10)
        XCTAssertEqual(GifPlan.range(duration: 10, part: (8, 5))?.length, 2)
        XCTAssertNil(GifPlan.range(duration: 10, part: (10, 1)))
        XCTAssertNil(GifPlan.range(duration: 10, part: (1, 0)))
    }

    func testConvertsPartOfAVideoToALoopingGif() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gif-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 640, height: 360), seconds: 3)

        var settings = GifSettings(fps: 10, maxWidth: 320, loopForever: true)
        settings.part = (1, 1)
        let gif = try await GifConverter.convert(source: video, settings: settings, into: dir) { _ in }

        XCTAssertEqual(gif.lastPathComponent, "clip.gif")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 320)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 180)
        let file = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let loop = (file[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        XCTAssertEqual(loop, 0)

        // A second conversion never overwrites the first.
        let again = try await GifConverter.convert(source: video, settings: settings, into: dir) { _ in }
        XCTAssertEqual(again.lastPathComponent, "clip 2.gif")
    }

    func testStartPastEndFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gif-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 64, height: 64), seconds: 1)
        var settings = GifSettings()
        settings.part = (5, 1)
        do {
            _ = try await GifConverter.convert(source: video, settings: settings, into: dir) { _ in }
            XCTFail("expected an error")
        } catch { guard case GifError.emptyRange = error else { return XCTFail("\(error)") } }
    }

    /// Writes a solid-colour H.264 video that changes colour every frame.
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
