import AVFoundation
import XCTest
@testable import Toolbox

final class MuteVideoTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mute-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testRemovesEveryAudioTrackAndKeepsThePictureAsIs() async throws {
        let source = dir.appendingPathComponent("Holiday.mov")
        try await makeVideoWithSound(at: source)
        let before = try Data(contentsOf: source)
        let originalCodec = try await codec(of: source)

        let outcome = try await VideoMuter.mute(source: source, into: dir) { _ in }

        guard case .muted(let result) = outcome else { return XCTFail("expected a muted file, got \(outcome)") }
        XCTAssertEqual(result.url.lastPathComponent, "Holiday (Muted).mov")
        XCTAssertFalse(result.reencoded)
        XCTAssertEqual(result.duration, 2, accuracy: 0.2)
        XCTAssertEqual(result.originalBytes, Int64(before.count))
        XCTAssertGreaterThan(result.originalBytes, result.newBytes)
        XCTAssertEqual(result.savedBytes, result.originalBytes - result.newBytes)

        let muted = AVURLAsset(url: result.url)
        let audio = try await muted.loadTracks(withMediaType: .audio)
        let video = try await muted.loadTracks(withMediaType: .video)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertEqual(video.count, 1)
        let mutedCodec = try await codec(of: result.url)
        let mutedSize = try await video[0].load(.naturalSize)
        XCTAssertEqual(mutedCodec, originalCodec, "picture is copied, not re-encoded")
        XCTAssertEqual(mutedSize, CGSize(width: 160, height: 90))
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is untouched")
    }

    func testKeepsTheTurnOfARotatedVideo() async throws {
        let source = dir.appendingPathComponent("Portrait.mov")
        try await makeVideoWithSound(at: source, rotation: .pi / 2)

        guard case .muted(let result) = try await VideoMuter.mute(source: source, into: dir, progress: { _ in }) else {
            return XCTFail("expected a muted file")
        }
        let t = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)[0].load(.preferredTransform)
        XCTAssertEqual(MediaInspector.rotation(of: t), 90)
    }

    func testKeepsMetadataSuchAsTheLocation() async throws {
        let source = dir.appendingPathComponent("Located.mov")
        try await makeVideoWithSound(at: source, location: "+37.3349-122.0090/")

        guard case .muted(let result) = try await VideoMuter.mute(source: source, into: dir, progress: { _ in }) else {
            return XCTFail("expected a muted file")
        }
        let report = try await MediaInspector.inspect(result.url)
        XCTAssertEqual(try XCTUnwrap(report.location).latitude, 37.3349, accuracy: 1e-6)
    }

    func testAVideoWithoutSoundIsReportedAndNothingIsWritten() async throws {
        let source = dir.appendingPathComponent("Quiet.mov")
        try await makeVideo(at: source)
        let outcome = try await VideoMuter.mute(source: source, into: dir) { _ in }
        XCTAssertEqual(outcome, .alreadySilent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Quiet (Muted).mov").path))
    }

    func testRefusesAFileWithNoVideo() async throws {
        let source = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        do {
            _ = try await VideoMuter.mute(source: source, into: dir) { _ in }
            XCTFail("a text file has no video")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testTwoVideosWithTheSameNameDoNotOverwriteEachOther() async throws {
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try await makeVideoWithSound(at: a.appendingPathComponent("Clip.mov"))
        try await makeVideoWithSound(at: b.appendingPathComponent("Clip.mov"))
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for source in [a, b] { _ = try await VideoMuter.mute(source: source.appendingPathComponent("Clip.mov"), into: out) { _ in } }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["Clip (Muted) 2.mov", "Clip (Muted).mov"])
    }

    @MainActor func testQueueMutesTheBatchAndTotalsTheSpaceSaved() async throws {
        let a = dir.appendingPathComponent("One.mov"), b = dir.appendingPathComponent("Two.mov"), quiet = dir.appendingPathComponent("Three.mov")
        try await makeVideoWithSound(at: a)
        try await makeVideoWithSound(at: b)
        try await makeVideo(at: quiet)
        let model = MuteVideoModel()
        model.add([a, b, quiet, a])
        XCTAssertEqual(model.items.count, 3, "the same file is not added twice")

        model.mute()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        defer { if let f = model.folder { try? FileManager.default.removeItem(at: f) } }

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.items.last?.status, .silent)
        XCTAssertEqual(model.savedBytes, model.results.reduce(0) { $0 + $1.savedBytes })
        XCTAssertFalse(model.hasPending)
    }

    // MARK: Helpers

    private func codec(of url: URL) async throws -> UInt32 {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)[0]
        return try await track.load(.formatDescriptions)[0].mediaSubType.rawValue
    }

    /// Two seconds of picture plus a two second tone, optionally turned or tagged with a location.
    private func makeVideoWithSound(at url: URL, rotation: Double = 0, location: String? = nil) async throws {
        let picture = dir.appendingPathComponent("pic-\(UUID()).mov"), tone = dir.appendingPathComponent("tone-\(UUID()).m4a")
        try await makeVideo(at: picture)
        try makeTone(at: tone)

        let composition = AVMutableComposition()
        let pictureAsset = AVURLAsset(url: picture), toneAsset = AVURLAsset(url: tone)  // tracks need their asset kept alive
        let videoSource = try await pictureAsset.loadTracks(withMediaType: .video)[0]
        let audioSource = try await toneAsset.loadTracks(withMediaType: .audio)[0]
        let v = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: videoSource, at: .zero)
        v.preferredTransform = CGAffineTransform(rotationAngle: rotation)
        let a = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), of: audioSource, at: .zero)

        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = url
        exporter.outputFileType = .mov
        if let location {
            let m = AVMutableMetadataItem()
            m.identifier = .quickTimeMetadataLocationISO6709
            m.value = location as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            exporter.metadata = [m]
        }
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, "\(String(describing: exporter.error))")
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

    private func makeVideo(at url: URL) async throws {
        let size = CGSize(width: 160, height: 90)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let b = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(i * 4 % 256), CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
