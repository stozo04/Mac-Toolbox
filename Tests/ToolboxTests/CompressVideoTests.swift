import AVFoundation
import XCTest
@testable import Toolbox

final class CompressVideoTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("compress-video-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Plan

    func testMaximumSizeCapsTheShorterSideAndKeepsTheShape() {
        func size(_ w: CGFloat, _ h: CGFloat, _ cap: Int?) -> CGSize { VideoCompressPlan.outputSize(source: CGSize(width: w, height: h), maxShortSide: cap) }
        XCTAssertEqual(size(1920, 1080, 720), CGSize(width: 1280, height: 720))
        XCTAssertEqual(size(3840, 2160, 1080), CGSize(width: 1920, height: 1080))
        // A vertical phone video: "720p" limits the width, not the height.
        XCTAssertEqual(size(1080, 1920, 720), CGSize(width: 720, height: 1280))
        XCTAssertEqual(size(1920, 1080, nil), CGSize(width: 1920, height: 1080))
    }

    func testVideosAreNeverEnlarged() {
        XCTAssertEqual(VideoCompressPlan.outputSize(source: CGSize(width: 640, height: 360), maxShortSide: 1080), CGSize(width: 640, height: 360))
        XCTAssertEqual(VideoCompressPlan.outputSize(source: CGSize(width: 852, height: 480), maxShortSide: 480), CGSize(width: 852, height: 480))
    }

    func testOddSizesRoundDownToEven() {
        XCTAssertEqual(VideoCompressPlan.outputSize(source: CGSize(width: 1001, height: 563), maxShortSide: nil), CGSize(width: 1000, height: 562))
        let capped = VideoCompressPlan.outputSize(source: CGSize(width: 1000, height: 563), maxShortSide: 480)
        XCTAssertEqual(capped.width.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(capped.height.truncatingRemainder(dividingBy: 2), 0)
    }

    func testBitrateFollowsQualityAndCodec() {
        let size = CGSize(width: 1920, height: 1080)
        func rate(_ q: VideoCompressQuality, _ c: VideoCompressCodec = .h264, hardware: Bool = false, source: Double? = nil, fps: Double = 30) -> Int {
            VideoCompressPlan.videoBitrate(size: size, frameRate: fps,
                                           settings: VideoCompressSettings(quality: q, codec: c, hardwareEncoder: hardware), sourceBitrate: source)
        }
        XCTAssertGreaterThan(rate(.high), rate(.balanced))
        XCTAssertGreaterThan(rate(.balanced), rate(.small))
        XCTAssertEqual(Double(rate(.balanced)), 4_354_000, accuracy: 20_000)  // 1080p30, 0.07 bits per pixel
        XCTAssertEqual(Double(rate(.balanced, .hevc)) / Double(rate(.balanced)), 0.55, accuracy: 0.01)
        XCTAssertGreaterThan(rate(.balanced, hardware: true), rate(.balanced))
        // 60 fps costs more than 30 but less than double.
        XCTAssertGreaterThan(rate(.balanced, fps: 60), rate(.balanced))
        XCTAssertLessThan(rate(.balanced, fps: 60), rate(.balanced) * 2)
    }

    func testAlreadySmallVideosAreNotGivenMoreBitsThanTheyHad() {
        let settings = VideoCompressSettings(quality: .high)
        let rate = VideoCompressPlan.videoBitrate(size: CGSize(width: 1920, height: 1080), frameRate: 30, settings: settings, sourceBitrate: 1_000_000)
        XCTAssertEqual(rate, 900_000)
        // And there is a floor, so a tiny or silent clip still gets a working encoder setting.
        XCTAssertEqual(VideoCompressPlan.videoBitrate(size: CGSize(width: 64, height: 64), frameRate: 30, settings: settings, sourceBitrate: nil), 100_000)
    }

    func testAudioIsStereoAtMostAndMonoGetsHalfTheBitrate() {
        let stereo = VideoCompressPlan.audioFormat(channels: 6, sampleRate: 48_000, quality: .balanced)
        XCTAssertEqual(stereo.channels, 2)
        XCTAssertEqual(stereo.bitrate, 128_000)
        XCTAssertEqual(stereo.sampleRate, 48_000)
        let mono = VideoCompressPlan.audioFormat(channels: 1, sampleRate: 22_050, quality: .high)
        XCTAssertEqual(mono.channels, 1)
        XCTAssertEqual(mono.bitrate, 80_000)
        XCTAssertEqual(mono.sampleRate, 44_100)
    }

    func testOutputNameMarksTheCopy() {
        XCTAssertEqual(VideoCompressor.outputBase(for: URL(fileURLWithPath: "/a/Holiday.mov")), "Holiday (Compressed)")
    }

    // MARK: Model

    @MainActor func testQueueSkipsDuplicatesAndNonVideos() throws {
        let video = dir.appendingPathComponent("a.mov")
        try makeFlatVideo(at: video)
        let text = dir.appendingPathComponent("notes.txt")
        try "hi".write(to: text, atomically: true, encoding: .utf8)

        let model = CompressVideoModel()
        model.add([video, video, text])
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.notice, "1 item(s) had no videos and were skipped.")
        model.add([dir])  // the folder holds the same video
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(model.hasPending)
        model.clear()
        XCTAssertFalse(model.hasItems)
    }

    @MainActor func testDefaultsMatchTheDesign() {
        let s = CompressVideoModel().settings
        XCTAssertEqual(s, VideoCompressSettings(quality: .balanced, codec: .h264, maxSize: .original, removeAudio: false, hardwareEncoder: false))
    }

    // MARK: Compressing

    func testCompressesToASmallerH264FileAndKeepsTheSound() async throws {
        let source = dir.appendingPathComponent("Holiday.mov")
        try await makeSource(at: source, size: CGSize(width: 640, height: 360))
        let before = try Data(contentsOf: source)

        let result = try compressed(await VideoCompressor.compress(source: source, settings: VideoCompressSettings(quality: .small), into: dir) { _ in })

        XCTAssertEqual(result.url.lastPathComponent, "Holiday (Compressed).mp4")
        XCTAssertEqual(result.originalBytes, Int64(before.count))
        XCTAssertLessThan(result.newBytes, result.originalBytes / 2)
        XCTAssertGreaterThan(result.savedFraction, 0.5)
        XCTAssertEqual(result.size, CGSize(width: 640, height: 360))
        let asset = AVURLAsset(url: result.url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize)
        let formats = try await track.load(.formatDescriptions)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(natural, CGSize(width: 640, height: 360))
        XCTAssertEqual(formats[0].mediaSubType.rawValue, kCMVideoCodecType_H264)
        XCTAssertEqual(audioCount, 1)
        XCTAssertEqual(duration, 2, accuracy: 0.2)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original must not change")
    }

    func testResizingDoesNotTurnASoundTailIntoBlackVideo() async throws {
        // One second of picture, two of sound: the re-rendered picture must stop where the real one does
        // (the composition reader ends with the video track; this guards against that changing).
        let source = dir.appendingPathComponent("tail.mov")
        try await makeSource(at: source, size: CGSize(width: 1280, height: 720), pictureSeconds: 1)
        let original = AVURLAsset(url: source)
        let sourceVideoEnd = try await original.loadTracks(withMediaType: .video)[0].load(.timeRange).end.seconds
        let sourceLength = try await original.load(.duration).seconds
        XCTAssertEqual(sourceVideoEnd, 1, accuracy: 0.05)
        XCTAssertEqual(sourceLength, 2, accuracy: 0.05, "the sound must run past the picture for this test to mean anything")
        let result = try compressed(await VideoCompressor.compress(
            source: source, settings: VideoCompressSettings(maxSize: .p480), into: dir) { _ in })
        let asset = AVURLAsset(url: result.url)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let end = try await video.load(.timeRange).end.seconds
        XCTAssertEqual(end, 1, accuracy: 0.1)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(audioCount, 1)
    }

    func testHEVCAndHardwareChoicesBothProduceAPlayableFile() async throws {
        let source = dir.appendingPathComponent("clip.mov")
        try await makeSource(at: source, size: CGSize(width: 640, height: 360))
        for hardware in [false, true] {
            let result = try compressed(await VideoCompressor.compress(
                source: source, settings: VideoCompressSettings(codec: .hevc, hardwareEncoder: hardware), into: dir) { _ in })
            let track = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)[0]
            let formats = try await track.load(.formatDescriptions)
            XCTAssertEqual(formats[0].mediaSubType.rawValue, kCMVideoCodecType_HEVC, "hardware \(hardware)")
            XCTAssertLessThan(result.newBytes, result.originalBytes)
        }
    }

    func testRemoveAudioDropsTheSoundtrack() async throws {
        let source = dir.appendingPathComponent("clip.mov")
        try await makeSource(at: source, size: CGSize(width: 640, height: 360))
        let result = try compressed(await VideoCompressor.compress(
            source: source, settings: VideoCompressSettings(removeAudio: true), into: dir) { _ in })
        let asset = AVURLAsset(url: result.url)
        let audioCount = try await asset.loadTracks(withMediaType: .audio).count
        let videoCount = try await asset.loadTracks(withMediaType: .video).count
        XCTAssertEqual(audioCount, 0)
        XCTAssertEqual(videoCount, 1)
    }

    func testMaximumSizeShrinksThePicture() async throws {
        let source = dir.appendingPathComponent("big.mov")
        try await makeSource(at: source, size: CGSize(width: 1280, height: 720), sound: false)
        let result = try compressed(await VideoCompressor.compress(
            source: source, settings: VideoCompressSettings(maxSize: .p480), into: dir) { _ in })
        XCTAssertEqual(result.size, CGSize(width: 852, height: 480))
        let track = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize)
        XCTAssertEqual(natural, CGSize(width: 852, height: 480))
    }

    /// A phone video is stored sideways with a flag that turns it. The rotation here carries no translation, as some tools write it.
    func testTurnedVideosStayUprightWithAndWithoutResizing() async throws {
        let source = dir.appendingPathComponent("phone.mov")
        try await makeSource(at: source, size: CGSize(width: 1280, height: 720), rotation: .pi / 2, sound: false)

        let same = try compressed(await VideoCompressor.compress(source: source, settings: VideoCompressSettings(), into: dir) { _ in })
        XCTAssertEqual(same.size, CGSize(width: 720, height: 1280))
        let sameTrack = try await AVURLAsset(url: same.url).loadTracks(withMediaType: .video)[0]
        let shown = try await sameTrack.load(.naturalSize).applying(sameTrack.load(.preferredTransform))
        XCTAssertEqual([abs(shown.width), abs(shown.height)], [720, 1280], "still turned, not squashed")

        let smaller = try compressed(await VideoCompressor.compress(
            source: source, settings: VideoCompressSettings(maxSize: .p480), into: dir) { _ in })
        XCTAssertEqual(smaller.size, CGSize(width: 480, height: 852))
        let image = try await frame(of: smaller.url)
        XCTAssertEqual([image.width, image.height], [480, 852])
        // The stored picture is light on top and dark below; turned a quarter, one side of the upright picture is light and the other dark.
        XCTAssertGreaterThan(abs(luma(image, x: 60, y: 426) - luma(image, x: 420, y: 426)), 100, "the picture is turned, not blank or squashed")
        XCTAssertLessThan(abs(luma(image, x: 240, y: 100) - luma(image, x: 240, y: 750)), 60)
    }

    func testNoNewFileIsKeptWhenItWouldNotBeSmaller() async throws {
        let source = dir.appendingPathComponent("tiny.mov")
        try makeFlatVideo(at: source)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let outcome = try await VideoCompressor.compress(source: source, settings: VideoCompressSettings(quality: .high), into: dir) { _ in }

        // AVAssetWriter's own scratch file ("….sb-…") takes a moment to disappear after a run.
        var after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        for _ in 0..<30 where after.contains(where: { $0.contains(".sb-") }) {
            try await Task.sleep(for: .milliseconds(100))
            after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        }
        switch outcome {
        case .compressed(let r):
            XCTAssertLessThan(r.newBytes, r.originalBytes)
            XCTAssertEqual(after.count, before.count + 1)
        case .notSmaller(let original, let new):
            XCTAssertGreaterThanOrEqual(new, original)
            XCTAssertEqual(after, before, "the copy that was not smaller must be removed")
        }
    }

    func testAFileWithoutVideoFails() async throws {
        let audio = dir.appendingPathComponent("tone.m4a")
        try makeTone(at: audio)
        do {
            _ = try await VideoCompressor.compress(source: audio, settings: VideoCompressSettings(), into: dir) { _ in }
            XCTFail("should have thrown")
        } catch let error as VideoCompressError {
            XCTAssertEqual(error.errorDescription, "This file has no video that can be read.")
        }
    }

    func testCancellingRemovesThePartialFile() async throws {
        let source = dir.appendingPathComponent("long.mov")
        try await makeSource(at: source, size: CGSize(width: 1280, height: 720), sound: false)
        final class Box: @unchecked Sendable { var task: Task<VideoCompressOutcome, Error>? }
        let box = Box()
        box.task = Task {
            try await VideoCompressor.compress(source: source, settings: VideoCompressSettings(codec: .hevc), into: dir) { p in
                if p > 0.02 { box.task?.cancel() }
            }
        }
        do {
            _ = try await XCTUnwrap(box.task).value
            XCTFail("the run should have been cancelled")
        } catch is CancellationError {
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("(Compressed)") }
            XCTAssertEqual(left, [], "a cancelled run must not leave a half-written file")
        }
    }

    func testDiscardingAPartialFileAlsoRemovesItsScratchFilesAndNothingElse() throws {
        let output = dir.appendingPathComponent("long (Compressed).mp4")
        let leftovers = ["long (Compressed).mp4", "long (Compressed).mp4.sb-1a2b3c", "long (Compressed).mp4.sb-9z8y7x"]
        let keep = ["long.mov", "long (Compressed) 2.mp4", "long (Compressed) 2.mp4.sb-4d5e6f", "long (Compressed).mp4.sbx"]
        for name in leftovers + keep { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }

        VideoCompressor.discard(output)

        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, keep.sorted())
    }

    // MARK: Helpers

    private func compressed(_ outcome: VideoCompressOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> VideoCompressResult {
        guard case .compressed(let result) = outcome else {
            XCTFail("expected a smaller file, got \(outcome)", file: file, line: line)
            throw CancellationError()
        }
        return result
    }

    private func frame(of url: URL) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }

    private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]) * 3 + Int(px[1]) * 6 + Int(px[2])) / 10
    }

    /// Two seconds of noisy picture at a high bitrate, so there is plenty to save; optionally with a tone and a rotation flag.
    private func makeSource(at url: URL, size: CGSize, rotation: Double = 0, sound: Bool = true, pictureSeconds: Double = 2) async throws {
        let picture = dir.appendingPathComponent("pic-\(UUID()).mov")
        try await writePicture(at: picture, size: size, seconds: 2, noisy: true, bitrate: 12_000_000, bands: rotation != 0)
        let pictureAsset = AVURLAsset(url: picture)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let v = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let pictureRange = CMTimeRange(start: .zero, duration: CMTime(seconds: pictureSeconds, preferredTimescale: 600))
        try v.insertTimeRange(pictureRange, of: try await pictureAsset.loadTracks(withMediaType: .video)[0], at: .zero)
        v.preferredTransform = CGAffineTransform(rotationAngle: rotation)
        var toneAsset: AVURLAsset?
        if sound {
            let tone = dir.appendingPathComponent("tone-\(UUID()).m4a")
            try makeTone(at: tone)
            let asset = AVURLAsset(url: tone)
            toneAsset = asset
            let a = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
            try a.insertTimeRange(range, of: try await asset.loadTracks(withMediaType: .audio)[0], at: .zero)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = url
        exporter.outputFileType = .mov
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, "\(String(describing: exporter.error))")
        withExtendedLifetime(toneAsset) {}
    }

    private func makeFlatVideo(at url: URL) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        Task.detached {
            do { try await self.writePicture(at: url, size: CGSize(width: 160, height: 90), seconds: 1, noisy: false, bitrate: 100_000, bands: false) } catch { failure = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
    }

    /// With `bands`, the top half of the stored picture is light and the bottom half dark, so a turned copy has light on one side.
    private func writePicture(at url: URL, size: CGSize, seconds: Int, noisy: Bool, bitrate: Int, bands: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]])
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
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b))
            let rowWords = CVPixelBufferGetBytesPerRow(b) / 8, height = CVPixelBufferGetHeight(b)
            let words = base.assumingMemoryBound(to: UInt64.self)
            if noisy {
                // Light grain on a flat tone: big at a high bitrate, but a smaller encode can leave the grain out, as with real footage.
                arc4random_buf(base, CVPixelBufferGetDataSize(b))
                for row in 0..<height {
                    for w in 0..<rowWords {
                        let top = bands && row < height / 2
                        words[row * rowWords + w] = (words[row * rowWords + w] & 0x0F0F_0F0F_0F0F_0F0F)
                            | (bands ? (top ? 0xC0C0_C0C0_C0C0_C0C0 : 0) : 0x4040_4040_4040_4040)
                    }
                }
            } else {
                memset(base, Int32(i * 4 % 256), CVPixelBufferGetDataSize(b))
            }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private func makeTone(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        do {  // the file is only finished when the file object goes away
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
            buffer.frameLength = 88200
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<88200 { samples[i] = Float(sin(Double(i) * 0.1) * 0.4) }
            try file.write(from: buffer)
        }
    }
}
