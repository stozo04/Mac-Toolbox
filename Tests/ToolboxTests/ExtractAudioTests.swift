import AVFoundation
import XCTest
@testable import Toolbox

final class ExtractAudioTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("extract-audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: M4A

    func testAACSoundtrackIsCopiedAsIsIntoM4A() async throws {
        let source = dir.appendingPathComponent("Holiday.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))
        let before = try Data(contentsOf: source)
        let sourceRate = try await dataRate(of: source)

        let result = try await extract(source, .init(format: .m4a, bitrate: .kbps128), ffmpeg: try Self.ffmpegWithMP3())

        XCTAssertEqual(result.url.lastPathComponent, "Holiday.m4a")
        XCTAssertTrue(result.copiedAsIs)
        XCTAssertEqual(result.duration, 2, accuracy: 0.1)
        XCTAssertGreaterThan(result.bytes, 0)
        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(audio.mChannelsPerFrame, 2)
        let copiedRate = try await dataRate(of: result.url)
        XCTAssertEqual(copiedRate, sourceRate, accuracy: sourceRate * 0.05, "the chosen bitrate is ignored when copying")
        let videoTracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is untouched")
    }

    func testCopiedAACDecodesToExactlyTheOriginalSound() async throws {
        let ffmpeg = try Self.ffmpegWithMP3()
        let source = dir.appendingPathComponent("Phone.mov")
        try await makeVideo(at: source, sound: .heAACv2)

        let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: .m4a), ffmpeg: ffmpeg) { _ in }

        guard case .extracted(let result) = outcome else { return XCTFail("expected an M4A") }
        XCTAssertTrue(result.copiedAsIs)
        let original = try await decoded(source, with: ffmpeg)
        let copied = try await decoded(result.url, with: ffmpeg)
        XCTAssertFalse(original.isEmpty)
        XCTAssertEqual(copied, original)
    }

    func testWithoutFFmpegTheCopyStillKeepsEveryPacket() async throws {
        let source = dir.appendingPathComponent("Phone.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))

        let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: .m4a), ffmpeg: nil) { _ in }

        guard case .extracted(let result) = outcome else { return XCTFail("expected an M4A") }
        XCTAssertTrue(result.copiedAsIs)
        let original = try await packets(of: source)
        let copied = try await packets(of: result.url)
        XCTAssertFalse(original.isEmpty)
        XCTAssertEqual(copied, original)
    }

    func testHEAACIsDecodedAtItsFullSampleRateAndChannels() async throws {
        let source = dir.appendingPathComponent("Phone.mov")
        try await makeVideo(at: source, sound: .heAACv2)
        let ffmpeg = try Self.ffmpegWithMP3()

        for format in [ExtractAudioFormat.wav, .aiff, .mp3] {
            let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: format), ffmpeg: ffmpeg) { _ in }
            guard case .extracted(let result) = outcome else { return XCTFail("expected \(format.rawValue)") }
            let audio = try await audioFormat(of: result.url)
            XCTAssertEqual(audio.mSampleRate, 44_100, format.rawValue)
            XCTAssertEqual(audio.mChannelsPerFrame, 2, format.rawValue)
        }
    }

    func testOtherSoundIsEncodedToAACAtTheChosenBitrate() async throws {
        let source = dir.appendingPathComponent("Interview.mov")
        try await makeVideo(at: source, sound: .pcm(channels: 2, sampleRate: 48_000))

        let result = try await extract(source, .init(format: .m4a, bitrate: .kbps192))

        XCTAssertFalse(result.copiedAsIs)
        XCTAssertEqual(result.duration, 2, accuracy: 0.1)
        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(audio.mSampleRate, 48_000)
        let rate = try await dataRate(of: result.url)
        XCTAssertEqual(rate, 192_000, accuracy: 192_000 * 0.15)
    }

    func testMonoSoundAtTheHighestBitrateStillEncodes() async throws {
        XCTAssertEqual(AudioExtractor.aacBitrate(.kbps320, channels: 1), AudioExtractor.maxMonoAACBitrate)
        XCTAssertEqual(AudioExtractor.aacBitrate(.kbps320, channels: 2), 320_000)
        let source = dir.appendingPathComponent("Voice.mov")
        try await makeVideo(at: source, sound: .pcm(channels: 1, sampleRate: 22_050))

        let result = try await extract(source, .init(format: .m4a, bitrate: .kbps320))

        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(audio.mChannelsPerFrame, 1)
        XCTAssertEqual(audio.mSampleRate, 44_100)
    }

    // MARK: WAV and AIFF

    func testWAVIsUncompressedAtTheVideosSampleRate() async throws {
        let source = dir.appendingPathComponent("Clip.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))

        let result = try await extract(source, .init(format: .wav, bitrate: .kbps128))

        XCTAssertEqual(result.url.pathExtension, "wav")
        XCTAssertFalse(result.copiedAsIs)
        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(audio.mBitsPerChannel, 16)
        XCTAssertEqual(audio.mSampleRate, 44_100)
        XCTAssertEqual(audio.mChannelsPerFrame, 2)
        XCTAssertEqual(audio.mFormatFlags & kAudioFormatFlagIsBigEndian, 0)
        let duration = try await AVURLAsset(url: result.url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
    }

    func testAIFFIsBigEndianPCM() async throws {
        let source = dir.appendingPathComponent("Clip.mov")
        try await makeVideo(at: source, sound: .pcm(channels: 2, sampleRate: 48_000))

        let result = try await extract(source, .init(format: .aiff, bitrate: .kbps128))

        XCTAssertEqual(result.url.pathExtension, "aiff")
        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(audio.mSampleRate, 48_000)
        XCTAssertNotEqual(audio.mFormatFlags & kAudioFormatFlagIsBigEndian, 0)
        let duration = try await AVURLAsset(url: result.url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
    }

    // MARK: MP3

    func testMP3IsEncodedWithLAMEAtTheChosenBitrate() async throws {
        let ffmpeg = try Self.ffmpegWithMP3()
        let source = dir.appendingPathComponent("Song.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))
        let before = try Data(contentsOf: source)
        let reports = Reports()

        let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: .mp3, bitrate: .kbps192),
                                                       ffmpeg: ffmpeg) { reports.add($0) }

        guard case .extracted(let result) = outcome else { return XCTFail("expected an MP3, got \(outcome)") }
        XCTAssertEqual(result.url.lastPathComponent, "Song.mp3")
        let audio = try await audioFormat(of: result.url)
        XCTAssertEqual(audio.mFormatID, kAudioFormatMPEGLayer3)
        let rate = try await dataRate(of: result.url)
        XCTAssertEqual(rate, 192_000, accuracy: 192_000 * 0.05)
        let duration = try await AVURLAsset(url: result.url).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)
        XCTAssertEqual(reports.last, 1)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is untouched")
    }

    func testMP3WithoutTheEncoderSaysSoAndLeavesNoFile() async throws {
        let source = dir.appendingPathComponent("Song.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))
        do {
            _ = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: .mp3), ffmpeg: nil) { _ in }
            XCTFail("there is no encoder")
        } catch {
            XCTAssertEqual(error as? ExtractAudioError, .noMP3Encoder)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Song.mp3").path))
    }

    func testAFailingEncoderLeavesNoFileAndExplainsWhy() async throws {
        let source = dir.appendingPathComponent("Song.mov")
        try await makeVideo(at: source, sound: .aac(channels: 2))
        do {
            _ = try await AudioExtractor.extract(source: source, into: dir, settings: .init(format: .mp3),
                                                 ffmpeg: URL(fileURLWithPath: "/usr/bin/false")) { _ in }
            XCTFail("the encoder failed")
        } catch {
            guard case .encoderFailed = error as? ExtractAudioError else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Song.mp3").path))
    }

    func testMP3ArgumentsLowerSampleRatesLAMECannotTake() {
        let source = URL(fileURLWithPath: "/in.mov"), output = URL(fileURLWithPath: "/out.mp3")
        let high = AudioExtractor.mp3Arguments(source: source, output: output, bitrate: .kbps320, channels: 2, sampleRate: 96_000)
        XCTAssertTrue(high.joined(separator: " ").contains("-c:a libmp3lame -b:a 320k -ac 2 -ar 48000"))
        let normal = AudioExtractor.mp3Arguments(source: source, output: output, bitrate: .kbps128, channels: 1, sampleRate: 44_100)
        XCTAssertFalse(normal.contains("-ar"))
        XCTAssertEqual(normal.last, "/out.mp3")
    }

    func testFFmpegProgressReadsLinesSplitAcrossChunks() {
        let reports = Reports()
        let parser = FFmpegProgress(total: 10) { reports.add($0) }
        parser.feed("frame=0\nout_time_us=250")
        XCTAssertTrue(reports.all.isEmpty, "half a line is not read")
        parser.feed("0000\nprogress=continue\nout_time_us=N/A\nout_time_us=5000000\n")
        XCTAssertEqual(reports.all, [0.25, 0.5])
    }

    // MARK: Cancelling

    func testCancellingAnOnDeviceExtractionLeavesNoFile() async throws {
        try await assertCancellingLeavesNoFile(format: .wav, ffmpeg: nil)
    }

    func testCancellingAnFFmpegExtractionLeavesNoFile() async throws {
        try await assertCancellingLeavesNoFile(format: .mp3, ffmpeg: try Self.ffmpegWithMP3())
    }

    private func assertCancellingLeavesNoFile(format: ExtractAudioFormat, ffmpeg: URL?) async throws {
        let source = dir.appendingPathComponent("Long.mov")
        try await makeVideo(at: source, sound: .pcm(channels: 2, sampleRate: 48_000), seconds: Self.longSeconds)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let reports = Reports()

        let job = Task {
            try await AudioExtractor.extract(source: source, into: out, settings: .init(format: format), ffmpeg: ffmpeg) { reports.add($0) }
        }
        for _ in 0..<400 where reports.all.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(reports.all.isEmpty, "progress was reported before cancelling")
        job.cancel()

        do {
            let outcome = try await job.value
            XCTFail("cancelled, but got \(outcome)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    @MainActor func testClearDuringARunLetsANewBatchFinishOnItsOwn() async throws {
        let long = dir.appendingPathComponent("Long.mov"), short = dir.appendingPathComponent("Short.mov")
        try await makeVideo(at: long, sound: .pcm(channels: 2, sampleRate: 48_000), seconds: Self.longSeconds)
        try await makeVideo(at: short, sound: .pcm(channels: 2, sampleRate: 48_000))
        let model = ExtractAudioModel()
        model.settings = .init(format: .wav)
        model.add([long])
        model.extract()
        for _ in 0..<400 where !isExtracting(model.items.first?.status) { try await Task.sleep(for: .milliseconds(5)) }

        model.clear()
        XCTAssertFalse(model.isRunning)
        model.add([short])
        model.extract()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        defer { if let f = model.folder { try? FileManager.default.removeItem(at: f) } }

        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.results.map(\.url.lastPathComponent), ["Short.wav"])
        let folder = try XCTUnwrap(model.folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Short.wav"])
    }

    @MainActor func testFailedVideosCanBeTriedAgain() async throws {
        let broken = dir.appendingPathComponent("Broken.mov")
        try Data(repeating: 7, count: 4096).write(to: broken)
        let model = ExtractAudioModel()
        model.add([broken])
        XCTAssertEqual(model.items.count, 1)

        model.extract()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        defer { if let f = model.folder { try? FileManager.default.removeItem(at: f) } }
        XCTAssertTrue(model.items[0].isFailed)
        XCTAssertTrue(model.hasPending, "a failed video can be tried again")

        try await makeVideo(at: dir.appendingPathComponent("Fixed.mov"), sound: .aac(channels: 2))
        try FileManager.default.removeItem(at: broken)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("Fixed.mov"), to: broken)
        model.extract()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.results.count, 1)
    }

    private func isExtracting(_ status: ExtractAudioModel.Status?) -> Bool {
        if case .extracting = status { true } else { false }
    }

    // MARK: Edge cases

    func testAVideoWithoutSoundIsReportedAndNothingIsWritten() async throws {
        let source = dir.appendingPathComponent("Quiet.mov")
        try await makeVideo(at: source, sound: nil)
        let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: .init(), ffmpeg: nil) { _ in }
        XCTAssertEqual(outcome, .noSoundtrack)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Quiet.m4a").path))
    }

    func testTwoVideosWithTheSameNameDoNotOverwriteEachOther() async throws {
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), out = dir.appendingPathComponent("out")
        for d in [a, b, out] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for d in [a, b] { try await makeVideo(at: d.appendingPathComponent("Clip.mov"), sound: .aac(channels: 1)) }

        for d in [a, b] {
            _ = try await AudioExtractor.extract(source: d.appendingPathComponent("Clip.mov"), into: out, settings: .init(), ffmpeg: nil) { _ in }
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["Clip 2.m4a", "Clip.m4a"])
    }

    @MainActor func testQueueExtractsTheBatchAndSkipsSilentVideos() async throws {
        let a = dir.appendingPathComponent("One.mov"), b = dir.appendingPathComponent("Two.mov"), quiet = dir.appendingPathComponent("Three.mov")
        try await makeVideo(at: a, sound: .aac(channels: 2))
        try await makeVideo(at: b, sound: .pcm(channels: 2, sampleRate: 48_000))
        try await makeVideo(at: quiet, sound: nil)
        let model = ExtractAudioModel()
        model.settings = .init(format: .wav, bitrate: .kbps256)
        model.add([a, b, quiet, a])
        XCTAssertEqual(model.items.count, 3, "the same file is not added twice")

        model.extract()
        for _ in 0..<200 where model.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        defer { if let f = model.folder { try? FileManager.default.removeItem(at: f) } }

        XCTAssertEqual(model.results.map(\.url.lastPathComponent), ["One.wav", "Two.wav"])
        XCTAssertEqual(model.items.last?.status, .noSoundtrack)
        XCTAssertFalse(model.hasPending)
    }

    // MARK: Helpers

    private static let longSeconds = 240.0

    private enum Sound {
        case aac(channels: Int)
        case heAACv2
        case pcm(channels: Int, sampleRate: Double)
    }

    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        var last: Double? { all.last }
    }

    static func ffmpegWithMP3() throws -> URL {
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../build/tools/ffmpeg").standardizedFileURL
        let candidates = [built, MediaTools.ffmpeg()].compactMap { $0 }
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) && hasLAME($0) }) else {
            throw XCTSkip("no ffmpeg with libmp3lame; run scripts/fetch-tools.sh")
        }
        return found
    }

    private static func hasLAME(_ ffmpeg: URL) -> Bool {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let listed = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(bytes: listed, encoding: .utf8) ?? "").contains("libmp3lame")
    }

    private func extract(_ source: URL, _ settings: ExtractAudioSettings, ffmpeg: URL? = nil) async throws -> ExtractAudioResult {
        let outcome = try await AudioExtractor.extract(source: source, into: dir, settings: settings, ffmpeg: ffmpeg) { _ in }
        guard case .extracted(let result) = outcome else {
            XCTFail("expected audio, got \(outcome)")
            throw CancellationError()
        }
        return result
    }

    private func audioFormat(of url: URL) async throws -> AudioStreamBasicDescription {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(descriptions.first)
        return try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(description)).pointee
    }

    private func decoded(_ url: URL, with ffmpeg: URL) async throws -> Data {
        let pcm = dir.appendingPathComponent("decoded-\(UUID()).raw")
        let result = try await Shell.run(ffmpeg.path, ["-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "s16le", pcm.path])
        XCTAssertTrue(result.succeeded, result.err)
        return try Data(contentsOf: pcm)
    }

    private func packets(of url: URL) async throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var sizes: [Int] = []
        while let buffer = output.copyNextSampleBuffer() {
            for i in 0..<CMSampleBufferGetNumSamples(buffer) { sizes.append(CMSampleBufferGetSampleSize(buffer, at: i)) }
        }
        return sizes
    }

    private func dataRate(of url: URL) async throws -> Double {
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        return Double(try await track.load(.estimatedDataRate))
    }

    private func makeTone(at url: URL, sound: Sound, seconds: Double) throws {
        let channels: Int, sampleRate: Double, settings: [String: Any]
        switch sound {
        case .aac(let c):
            (channels, sampleRate) = (c, 44_100)
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        case .heAACv2:
            (channels, sampleRate) = (2, 44_100)
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC_HE_V2, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        case .pcm(let c, let rate):
            (channels, sampleRate) = (c, rate)
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        }
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        var seed: UInt32 = 0x9E37_79B9
        for channel in 0..<channels {
            for i in 0..<Int(frames) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Float(seed >> 8) / Float(1 << 24) * 0.4 - 0.2
                data[channel][i] = Float(sin(Double(i) * 0.05 * Double(channel + 1)) * 0.4) + noise
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private func makeVideo(at url: URL, sound: Sound?, seconds: Double = 2) async throws {
        let picture = dir.appendingPathComponent("pic-\(UUID()).mov")
        try await makePicture(at: picture)
        guard let sound else { return try FileManager.default.moveItem(at: picture, to: url) }
        let toneExtension = if case .pcm = sound { "caf" } else { "m4a" }
        let tone = dir.appendingPathComponent("tone-\(UUID()).\(toneExtension)")
        try makeTone(at: tone, sound: sound, seconds: seconds)

        let composition = AVMutableComposition()
        let pictureAsset = AVURLAsset(url: picture), toneAsset = AVURLAsset(url: tone)
        let two = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        let v = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try v.insertTimeRange(two, of: try await pictureAsset.loadTracks(withMediaType: .video)[0], at: .zero)
        let a = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let soundRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try a.insertTimeRange(soundRange, of: try await toneAsset.loadTracks(withMediaType: .audio)[0], at: .zero)

        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = url
        exporter.outputFileType = .mov
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, "\(String(describing: exporter.error))")
        try? FileManager.default.removeItem(at: picture)
        try? FileManager.default.removeItem(at: tone)
    }

    private func makePicture(at url: URL) async throws {
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
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &buffer)
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
