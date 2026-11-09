import AVFoundation
import ImageIO
import XCTest
@testable import Toolbox

final class ExtractFramesTests: XCTestCase {
    private func settings(_ mode: FrameMode, _ change: (inout FrameSettings) -> Void = { _ in }) -> FrameSettings {
        var s = FrameSettings(mode: mode)
        change(&s)
        return s
    }

    // MARK: Plan

    func testEveryNSecondsStartsAtFirstFrameAndStopsBeforeTheEnd() {
        XCTAssertEqual(FramePlan.times(duration: 10, settings: settings(.everySeconds)), [0, 5])
        XCTAssertEqual(FramePlan.times(duration: 10.5, settings: settings(.everySeconds)), [0, 5, 10])
        // A clip shorter than the gap still gives its first frame.
        XCTAssertEqual(FramePlan.times(duration: 1, settings: settings(.everySeconds)), [0])
    }

    func testFramesPerSecond() {
        let t = FramePlan.times(duration: 2, settings: settings(.perSecond) { $0.fps = 10 })
        XCTAssertEqual(t.count, 20)
        XCTAssertEqual(t.last!, 1.9, accuracy: 1e-9)
        // Out-of-range rates are clamped to 1...30.
        XCTAssertEqual(FramePlan.times(duration: 1, settings: settings(.perSecond) { $0.fps = 99 }).count, 30)
    }

    func testSetNumberIsSpreadEvenly() {
        let t = FramePlan.times(duration: 10, settings: settings(.total) { $0.total = 4 })
        XCTAssertEqual(t, [0, 2.5, 5, 7.5])
        XCTAssertEqual(FramePlan.times(duration: 10, settings: settings(.total) { $0.total = 1 }), [0])
    }

    func testManualPlansNothing() {
        XCTAssertTrue(FramePlan.times(duration: 10, settings: settings(.manual)).isEmpty)
    }

    func testRangeIsClampedToTheVideo() {
        let s = settings(.everySeconds) { $0.interval = 1; $0.range = (8, 20) }
        XCTAssertEqual(FramePlan.times(duration: 10, settings: s), [8, 9])
        XCTAssertEqual(FramePlan.times(duration: 10, settings: settings(.everySeconds) { $0.interval = 1; $0.range = (2, 4) }), [2, 3])
        XCTAssertEqual(FramePlan.times(duration: 10, settings: settings(.everySeconds) { $0.interval = 1; $0.range = (3, nil) }).count, 7)
        XCTAssertTrue(FramePlan.times(duration: 10, settings: settings(.everySeconds) { $0.range = (10, nil) }).isEmpty)
        XCTAssertTrue(FramePlan.times(duration: 0, settings: settings(.everySeconds)).isEmpty)
        XCTAssertTrue(FramePlan.times(duration: .nan, settings: settings(.everySeconds)).isEmpty)
    }

    func testHugeRunsAreCappedSoTheyCanBeRefused() {
        let t = FramePlan.times(duration: 3600, settings: settings(.perSecond) { $0.fps = 30 })
        XCTAssertEqual(t.count, FramePlan.maxFrames + 1)
    }

    func testFileNames() {
        XCTAssertEqual(FramePlan.fileName(base: "Clip", index: 1, time: 5.25, format: .png), "Clip_0001_00m05.250s.png")
        XCTAssertEqual(FramePlan.fileName(base: "Clip", index: 12, time: 75, format: .jpeg), "Clip_0012_01m15.000s.jpg")
        XCTAssertEqual(FramePlan.fileName(base: "a b", index: 3, time: 3725.5, format: .heic), "a b_0003_62m05.500s.heic")
    }

    func testSummary() {
        XCTAssertEqual(FramePlan.summary(settings(.everySeconds)), "One frame every 5.0 s, starting at the first frame.")
        XCTAssertTrue(FramePlan.summary(settings(.total) { $0.total = 1 }).hasPrefix("1 frame spread"))
    }

    // MARK: Extraction

    func testExtractsFramesIntoAFolderNextToTheVideo() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 640, height: 360), seconds: 3)
        let before = try Data(contentsOf: video)

        let s = settings(.everySeconds) { $0.interval = 1; $0.maxSide = 320 }
        let result = try await FrameExtractor.extract(source: video, settings: s, destination: dir) { _, _ in }

        XCTAssertEqual(result.folder?.lastPathComponent, "clip Frames")
        XCTAssertEqual(result.frames.map(\.lastPathComponent),
                       ["clip_0001_00m00.000s.png", "clip_0002_00m01.000s.png", "clip_0003_00m02.000s.png"])
        XCTAssertNil(result.zip)
        let size = try pixelSize(result.frames[0])
        XCTAssertEqual(size, CGSize(width: 320, height: 180))
        XCTAssertEqual(try Data(contentsOf: video), before, "the original must not change")

        // Running again never overwrites the first run; a size bigger than the video is not enlarged.
        let again = try await FrameExtractor.extract(source: video, settings: settings(.total) { $0.total = 2; $0.maxSide = 1920; $0.format = .jpeg },
                                                     destination: dir) { _, _ in }
        XCTAssertEqual(again.folder?.lastPathComponent, "clip Frames 2")
        XCTAssertEqual(again.frames.map(\.pathExtension), ["jpg", "jpg"])
        XCTAssertEqual(try pixelSize(again.frames[0]), CGSize(width: 640, height: 360))
    }

    func testZipOnlyLeavesJustTheArchive() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 64, height: 64), seconds: 2)

        let s = settings(.perSecond) { $0.fps = 2; $0.output = .zipOnly; $0.format = .heic }
        let result = try await FrameExtractor.extract(source: video, settings: s, destination: dir) { _, _ in }

        XCTAssertNil(result.folder)
        XCTAssertEqual(result.count, 4)
        let zip = try XCTUnwrap(result.zip)
        XCTAssertEqual(zip.lastPathComponent, "clip Frames.zip")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), ["clip Frames.zip", "clip.mov"])

        let listing = try await Shell.run("/usr/bin/zipinfo", ["-1", zip.path])
        let names = listing.out.split(separator: "\n").filter { $0.hasSuffix(".heic") }
        XCTAssertEqual(names.count, 4)
        XCTAssertFalse(listing.out.contains("__MACOSX"))
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("clip Frames/") })
    }

    func testImagesAndZipKeepsBoth() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 64, height: 64), seconds: 1)
        let result = try await FrameExtractor.extract(source: video, settings: settings(.total) { $0.total = 3; $0.output = .imagesAndZip },
                                                      destination: dir) { _, _ in }
        XCTAssertEqual(result.frames.count, 3)
        XCTAssertNotNil(result.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.zip).path))
    }

    func testSaveOneFrameNumbersAfterExistingOnes() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 64, height: 64), seconds: 2)
        let folder = dir.appendingPathComponent("clip Frames")
        let first = try await FrameExtractor.extractOne(source: video, at: 0.5, settings: settings(.manual), folder: folder)
        let second = try await FrameExtractor.extractOne(source: video, at: 1.5, settings: settings(.manual), folder: folder)
        XCTAssertEqual(first.lastPathComponent, "clip_0001_00m00.500s.png")
        XCTAssertEqual(second.lastPathComponent, "clip_0002_00m01.500s.png")
        // The exact end of the video is after its last frame; that frame is saved instead of failing.
        let end = try await FrameExtractor.extractOne(source: video, at: 2.0, settings: settings(.manual), folder: folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: end.path))
    }

    func testStartPastEndFailsAndLeavesNothing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("clip.mov")
        try await makeVideo(at: video, size: CGSize(width: 64, height: 64), seconds: 1)
        do {
            _ = try await FrameExtractor.extract(source: video, settings: settings(.everySeconds) { $0.range = (5, nil) },
                                                 destination: dir) { _, _ in }
            XCTFail("expected an error")
        } catch { guard case FrameError.emptyRange = error else { return XCTFail("\(error)") } }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["clip.mov"])
    }

    // MARK: Helpers

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func pixelSize(_ url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0, height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
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
