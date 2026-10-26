import AVFoundation
import XCTest
@testable import Toolbox

final class TrimVideoTests: XCTestCase {
    func testSelectionHandlesCannotCross() {
        var s = TrimSelection(duration: 10)
        XCTAssertTrue(s.isWholeClip)
        s.setEnd(4)
        s.setStart(9)
        XCTAssertEqual(s.start, 4 - s.minimumLength, accuracy: 0.0001)
        s.setStart(-5)
        XCTAssertEqual(s.start, 0)
        s.setEnd(99)
        XCTAssertEqual(s.end, 10)
        XCTAssertTrue(s.isWholeClip)
    }

    func testTimeFormatAndParse() {
        XCTAssertEqual(TrimTime.format(5.25), "0:05.25")
        XCTAssertEqual(TrimTime.format(59.999), "1:00.00")
        XCTAssertEqual(TrimTime.format(3723.5), "1:02:03.50")
        XCTAssertEqual(TrimTime.parse("62.5"), 62.5)
        XCTAssertEqual(TrimTime.parse("1:02.5"), 62.5)
        XCTAssertEqual(TrimTime.parse("1:02:03"), 3723)
        XCTAssertNil(TrimTime.parse("abc"))
        XCTAssertNil(TrimTime.parse("1.5:02"))
        XCTAssertNil(TrimTime.parse("-3"))
    }

    func testOutputNaming() {
        let src = URL(fileURLWithPath: "/a/My Clip.MOV")
        XCTAssertEqual(VideoTrimmer.outputName(for: src, ext: "mov"), "My Clip (Trimmed).mov")
        XCTAssertEqual(VideoTrimmer.outputType(forExtension: "MP4").ext, "mp4")
        XCTAssertEqual(VideoTrimmer.outputType(forExtension: "avi").ext, "mov")
    }

    func testTrimsGeneratedClipWithoutTouchingOriginal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("clip.mov")
        try await makeClip(at: source, seconds: 4)
        let before = try Data(contentsOf: source)

        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try await VideoTrimmer.trim(source: source, start: 1, end: 3, into: out) { _ in }

        XCTAssertEqual(result.url.lastPathComponent, "clip (Trimmed).mov")
        let length = try await AVURLAsset(url: result.url).load(.duration).seconds
        XCTAssertEqual(length, 2, accuracy: 0.5)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testRejectsFileWithoutVideo() async throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).mov")
        try Data("not a video".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        do {
            _ = try await VideoTrimmer.trim(source: bogus, start: 0, end: 1, into: FileManager.default.temporaryDirectory) { _ in }
            XCTFail("expected an error")
        } catch {}
    }

    /// A small H.264 clip of changing solid colors, 10 fps.
    private func makeClip(at url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 5 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
