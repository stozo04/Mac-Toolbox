import AVFoundation
import XCTest
@testable import Toolbox

final class TrimAudioTests: XCTestCase {
    private var dir: URL!
    private let sampleRate = 44_100.0
    private let toneSeconds = 4.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("trim-audio-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        killProgramsLeftRunning()
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Plan

    func testSameFormatWithoutFadesIsCopiedAsIs() {
        let plan = TrimAudioPlan(sourceExtension: "MP3", sample: .init(bitDepth: 0), settings: .init())
        XCTAssertTrue(plan.copiesAsIs)
        XCTAssertTrue(plan.keepsSoundUnchanged)
        XCTAssertEqual(plan.fileExtension, "mp3")
        XCTAssertEqual(plan.codecArguments, ["-c:a", "copy"])
    }

    func testLosslessFormatsAreRewrittenSoTheCutIsSampleExact() {
        let plan = TrimAudioPlan(sourceExtension: "WAV", sample: .init(bitDepth: 24), settings: .init())
        XCTAssertFalse(plan.copiesAsIs)
        XCTAssertTrue(plan.keepsSoundUnchanged)
        XCTAssertEqual(plan.fileExtension, "wav")
        XCTAssertEqual(plan.codecArguments, ["-c:a", "pcm_s24le"])
    }

    func testFloatPCMStaysFloat() {
        let wav = TrimAudioPlan(sourceExtension: "wav", sample: .init(bitDepth: 32, isFloat: true), settings: .init())
        let aiff = TrimAudioPlan(sourceExtension: "aiff", sample: .init(bitDepth: 64, isFloat: true), settings: .init(format: .aiff))
        XCTAssertEqual(wav.codecArguments, ["-c:a", "pcm_f32le"])
        XCTAssertTrue(wav.keepsSoundUnchanged)
        XCTAssertEqual(aiff.codecArguments, ["-c:a", "pcm_f64be"])
    }

    func testAppleLosslessStaysLossless() {
        let alac = SourceSampleFormat(bitDepth: 16, isAppleLossless: true)
        let untouched = TrimAudioPlan(sourceExtension: "m4a", sample: alac, settings: .init())
        let faded = TrimAudioPlan(sourceExtension: "m4a", sample: alac, settings: .init(fades: .init(fadeIn: .one)))
        let asAAC = TrimAudioPlan(sourceExtension: "m4a", sample: alac, settings: .init(format: .m4a))
        XCTAssertFalse(untouched.copiesAsIs, "ALAC packets are too long for an exact cut, so it is rewritten")
        XCTAssertTrue(untouched.keepsSoundUnchanged)
        XCTAssertEqual(untouched.codecArguments, ["-c:a", "alac"])
        XCTAssertEqual(faded.codecArguments, ["-c:a", "alac"])
        XCTAssertEqual(asAAC.codecArguments, ["-c:a", "aac", "-b:a", TrimAudioPlan.aacBitrate], "choosing M4A (AAC) still means AAC")
    }

    func testFadesReencodeInTheSourceFormat() {
        let settings = TrimAudioSettings(format: .original, fades: .init(fadeIn: .one))
        let plan = TrimAudioPlan(sourceExtension: "flac", sample: .init(bitDepth: 24), settings: settings)
        XCTAssertFalse(plan.copiesAsIs)
        XCTAssertEqual(plan.fileExtension, "flac")
        XCTAssertEqual(plan.codecArguments, ["-c:a", "flac"])
    }

    func testFadesOnAFormatToolboxCannotWriteFallBackToM4A() {
        let settings = TrimAudioSettings(format: .original, fades: .init(fadeOut: .two))
        let plan = TrimAudioPlan(sourceExtension: "ogg", sample: .init(bitDepth: 0), settings: settings)
        XCTAssertEqual(plan.fileExtension, "m4a")
        XCTAssertEqual(plan.codecArguments, ["-c:a", "aac", "-b:a", TrimAudioPlan.aacBitrate])
    }

    func testPCMKeepsHighResolution() {
        let wav24 = TrimAudioPlan(sourceExtension: "wav", sample: .init(bitDepth: 24), settings: .init(format: .wav))
        let wav16 = TrimAudioPlan(sourceExtension: "mp3", sample: .init(bitDepth: 0), settings: .init(format: .wav))
        let aiff24 = TrimAudioPlan(sourceExtension: "aif", sample: .init(bitDepth: 24), settings: .init(format: .aiff))
        let wav32 = TrimAudioPlan(sourceExtension: "wav", sample: .init(bitDepth: 32), settings: .init(format: .wav))
        XCTAssertEqual(wav24.codecArguments, ["-c:a", "pcm_s24le"])
        XCTAssertEqual(wav16.codecArguments, ["-c:a", "pcm_s16le"])
        XCTAssertEqual(aiff24.codecArguments, ["-c:a", "pcm_s24be"])
        XCTAssertEqual(aiff24.fileExtension, "aiff")
        XCTAssertEqual(wav32.codecArguments, ["-c:a", "pcm_s32le"])
    }

    func testChosenFormatAlwaysReencodes() {
        let plan = TrimAudioPlan(sourceExtension: "mp3", sample: .init(bitDepth: 0), settings: .init(format: .mp3))
        XCTAssertFalse(plan.copiesAsIs)
        XCTAssertEqual(plan.codecArguments, ["-c:a", "libmp3lame", "-b:a", TrimAudioPlan.mp3Bitrate])
    }

    // MARK: Fades

    func testFadesNeverRunPastTheSelection() {
        let fades = TrimFades(fadeIn: .three, fadeOut: .three)
        let (fadeIn, fadeOut) = fades.seconds(within: 4)
        XCTAssertEqual(fadeIn, 3)
        XCTAssertEqual(fadeOut, 1)
    }

    func testFadeFilter() {
        XCTAssertEqual(AudioTrimmer.fadeFilter(TrimFades(), length: 10), [])
        XCTAssertEqual(AudioTrimmer.fadeFilter(TrimFades(fadeIn: .one, fadeOut: .two), length: 10),
                       ["-af", "afade=t=in:st=0:d=1.000,afade=t=out:st=8.000:d=2.000"])
    }

    func testArgumentsSeekTheInputAndKeepOnlyTheFirstSoundtrack() {
        let job = TrimAudioJob(source: URL(fileURLWithPath: "/tmp/Song.mp3"), start: 1.5, end: 4, sample: .init(bitDepth: 0), settings: .init())
        let arguments = AudioTrimmer.arguments(for: job, output: URL(fileURLWithPath: "/tmp/out.mp3"))
        let input = try? XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertEqual(arguments[(input ?? 0) - 2...(input ?? 0) + 3], ["-ss", "1.500", "-i", "/tmp/Song.mp3", "-t", "2.500"])
        XCTAssertTrue(arguments.contains("0:a:0"))
        XCTAssertEqual(arguments.last, "/tmp/out.mp3")
    }

    // MARK: Waveform

    func testPeakBinsKeepTheLoudestSampleOfEachBin() {
        var bins = PeakBins(count: 2, totalFrames: 4)
        bins.add([0.1, -0.5])
        bins.add([0.25, 0])
        XCTAssertEqual(bins.values, [0.5, 0.25])
        XCTAssertEqual(bins.normalized, [1, 0.5])
    }

    func testWaveformOfARealFile() async throws {
        let source = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: source)
        let info = try await AudioWaveform.info(of: source)
        XCTAssertEqual(info.duration, toneSeconds, accuracy: 0.01)
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sample, SourceSampleFormat(bitDepth: 16))
        XCTAssertEqual(info.summary, "44.1 kHz · Stereo")

        let peaks = try await AudioWaveform.peaks(of: source, duration: info.duration, count: 40)
        XCTAssertEqual(peaks.count, 40)
        XCTAssertEqual(peaks.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertGreaterThan(peaks.min() ?? 0, 0.5, "a steady tone fills every bar")
    }

    func testAFileWithoutSoundIsRejected() async throws {
        let text = dir.appendingPathComponent("Notes.txt")
        try Data("hello".utf8).write(to: text)
        do {
            _ = try await AudioWaveform.info(of: text)
            XCTFail("expected an error")
        } catch {}
    }

    // MARK: Trimming with ffmpeg

    func testTrimKeepsExactlyTheSelectedSamplesWithoutTouchingTheOriginal() async throws {
        let ffmpeg = try ExtractAudioTests.ffmpegWithMP3()
        let source = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: source)
        let before = try Data(contentsOf: source)
        let job = TrimAudioJob(source: source, start: 1, end: 3, sample: .init(bitDepth: 16), settings: .init())

        let result = try await AudioTrimmer.trim(job, into: dir, ffmpeg: ffmpeg) { _ in }

        XCTAssertEqual(result.url.lastPathComponent, "Tone (Trimmed).wav")
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(file.length, AVAudioFramePosition(sampleRate * 2))
        XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        let original = try mono(source), trimmed = try mono(result.url)
        let offset = Int(sampleRate)
        XCTAssertEqual(Array(trimmed[0..<100]), Array(original[offset..<offset + 100]), "the cut lands on the exact sample")
        XCTAssertEqual(try Data(contentsOf: source), before)

        let second = try await AudioTrimmer.trim(job, into: dir, ffmpeg: ffmpeg) { _ in }
        XCTAssertEqual(second.url.lastPathComponent, "Tone (Trimmed) 2.wav")
    }

    func testCancellingATrimStopsFFmpegAndRemovesTheUnfinishedFile() async throws {
        let ffmpeg = try ExtractAudioTests.ffmpegWithMP3()
        let halfAnHour = 1800.0
        let source = dir.appendingPathComponent("Long.wav")
        let made = try await Shell.run(ffmpeg.path, ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                                                     "-t", "\(halfAnHour)", "-y", source.path], timeout: .quick)
        XCTAssertTrue(made.succeeded, made.err)
        let job = TrimAudioJob(source: source, start: 0, end: halfAnHour, sample: .init(bitDepth: 16), settings: .init(format: .mp3))
        let folder = try XCTUnwrap(dir)
        let reported = Locked(false)
        let trim = Task.detached { try await AudioTrimmer.trim(job, into: folder, ffmpeg: ffmpeg) { _ in reported.set(true) } }
        try await waitUntil("ffmpeg reports progress") { reported.value }
        let encoder = try XCTUnwrap(Shell.livePIDs.first, "ffmpeg had already finished")

        trim.cancel()

        guard case .failure(let error) = await trim.result else { return XCTFail("a cancelled trim returned a file") }
        XCTAssertTrue(error is CancellationError, "threw \(error)")
        XCTAssertFalse(isRunning(encoder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Long.wav"])
    }

    func testCompressedFormatsAreCopiedAsIs() async throws {
        let ffmpeg = try ExtractAudioTests.ffmpegWithMP3()
        let tone = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: tone)
        let mp3 = try await AudioTrimmer.trim(TrimAudioJob(source: tone, start: 0, end: toneSeconds, sample: .init(bitDepth: 16), settings: .init(format: .mp3)),
                                              into: dir, ffmpeg: ffmpeg) { _ in }

        let result = try await AudioTrimmer.trim(TrimAudioJob(source: mp3.url, start: 1, end: 3, sample: .init(bitDepth: 0), settings: .init()),
                                                 into: dir, ffmpeg: ffmpeg) { _ in }

        XCTAssertTrue(result.copiedAsIs)
        XCTAssertEqual(result.url.pathExtension, "mp3")
        let file = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2, accuracy: 0.1)
    }

    func testTrimToMP3WithFades() async throws {
        let ffmpeg = try ExtractAudioTests.ffmpegWithMP3()
        let source = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: source)
        let settings = TrimAudioSettings(format: .mp3, fades: .init(fadeIn: .one, fadeOut: .one))
        let job = TrimAudioJob(source: source, start: 0.5, end: 3.5, sample: .init(bitDepth: 16), settings: settings)

        let result = try await AudioTrimmer.trim(job, into: dir, ffmpeg: ffmpeg) { _ in }

        XCTAssertFalse(result.copiedAsIs)
        XCTAssertEqual(result.url.pathExtension, "mp3")
        let samples = try mono(result.url)
        let rate = sampleRate
        XCTAssertEqual(Double(samples.count) / rate, 3, accuracy: 0.1)
        let start = rms(samples, from: 0, seconds: 0.05, rate: rate)
        let middle = rms(samples, from: 1.4, seconds: 0.2, rate: rate)
        let end = rms(samples, from: Double(samples.count) / rate - 0.05, seconds: 0.05, rate: rate)
        XCTAssertGreaterThan(middle, 0.1)
        XCTAssertLessThan(start, middle * 0.2, "fades in from silence")
        XCTAssertLessThan(end, middle * 0.2, "fades out to silence")
    }

    func testFloatAndAppleLosslessSourcesAreRecognisedAndKept() async throws {
        let ffmpeg = try ExtractAudioTests.ffmpegWithMP3()
        let tone = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: tone)
        let float = dir.appendingPathComponent("Float.wav"), alac = dir.appendingPathComponent("Lossless.m4a")
        for (output, codec) in [(float, "pcm_f32le"), (alac, "alac")] {
            let made = try await Shell.run(ffmpeg.path, ["-nostdin", "-v", "error", "-i", tone.path, "-c:a", codec, "-y", output.path], timeout: .quick)
            XCTAssertTrue(made.succeeded, made.err)
        }

        let floatInfo = try await AudioWaveform.info(of: float)
        let alacInfo = try await AudioWaveform.info(of: alac)
        XCTAssertTrue(floatInfo.sample.isFloat)
        XCTAssertTrue(alacInfo.sample.isAppleLossless)

        let trimmed = try await AudioTrimmer.trim(TrimAudioJob(source: float, start: 1, end: 3, sample: floatInfo.sample, settings: .init()),
                                                  into: dir, ffmpeg: ffmpeg) { _ in }
        let trimmedInfo = try await AudioWaveform.info(of: trimmed.url)
        XCTAssertEqual(trimmedInfo.sample, floatInfo.sample)

        let faded = try await AudioTrimmer.trim(TrimAudioJob(source: alac, start: 1, end: 3, sample: alacInfo.sample,
                                                             settings: .init(fades: .init(fadeIn: .one))), into: dir, ffmpeg: ffmpeg) { _ in }
        let fadedInfo = try await AudioWaveform.info(of: faded.url)
        XCTAssertTrue(fadedInfo.sample.isAppleLossless)
    }

    @MainActor
    func testOpeningASecondFileWhileTheFirstLoadsKeepsTheSecond() async throws {
        let first = dir.appendingPathComponent("First.wav"), second = dir.appendingPathComponent("Second.wav")
        try makeTone(at: first)
        try makeTone(at: second, seconds: 2)
        let model = TrimAudioModel()

        model.load(first)
        model.load(second)
        try await waitUntil(timeout: .seconds(30), "the file is loaded and ready to play") { !model.isLoading && model.isReadyToPlay }

        XCTAssertEqual(model.file, second)
        XCTAssertEqual(model.selection.duration, 2, accuracy: 0.01)
        XCTAssertTrue(model.isReadyToPlay, "the editor only shows once the player can seek")
        model.playSelection()
        model.close()
    }

    @MainActor
    func testPlaySelectionBeforeTheFileIsReadyDoesNothing() {
        let model = TrimAudioModel()
        XCTAssertFalse(model.isReadyToPlay)
        model.playSelection()
        XCTAssertFalse(model.isPlaying)
    }

    private typealias HeldTrim = (job: TrimAudioJob, folder: URL, finish: CheckedContinuation<TrimAudioResult, Error>)

    @MainActor private func makeModelWithHeldSaves(_ held: Locked<[HeldTrim]>) -> TrimAudioModel {
        TrimAudioModel(outputParent: dir, trim: { job, folder, _ in
            try await withCheckedThrowingContinuation { finish in held.update { $0.append((job, folder, finish)) } }
        })
    }

    @MainActor private func open(_ url: URL, in model: TrimAudioModel) async throws {
        model.load(url)
        try await waitUntil(timeout: .seconds(30), "\(url.lastPathComponent) is loaded") { !model.isLoading && model.isReadyToPlay }
        model.setFormat(.mp3)
    }

    @MainActor
    func testASaveLeftBehindByOpeningAnotherFileCannotChangeTheNewSave() async throws {
        let first = dir.appendingPathComponent("First.wav"), second = dir.appendingPathComponent("Second.wav")
        try makeTone(at: first)
        try makeTone(at: second, seconds: 2)
        let held = Locked<[HeldTrim]>([])
        let model = makeModelWithHeldSaves(held)
        addTeardownBlock { await model.close() }
        try await open(first, in: model)
        model.save()
        try await waitUntil("the first save starts") { held.value.count == 1 }

        try await open(second, in: model)
        XCTAssertEqual(model.saveState, .idle)
        model.save()
        try await waitUntil("the second save starts") { held.value.count == 2 }
        try held.value.element(at: 0).finish.resume(throwing: CancellationError())
        try await pause(for: .milliseconds(50), because: "the old save's ending would land on a later main-actor turn")

        XCTAssertEqual(model.saveState, .saving(0), "the old save ending must not make the new one look idle")
        let saved = TrimAudioResult(url: dir.appendingPathComponent("Second (Trimmed).mp3"), copiedAsIs: false)
        try held.value.element(at: 1).finish.resume(returning: saved)
        try await waitUntil("the second save lands") { model.saveState == .done(saved) }
        XCTAssertEqual(try held.value.element(at: 1).job.source, second)
    }

    @MainActor
    func testAFinishedSaveOfAClosedFileIsNotShownOnTheNextFile() async throws {
        let first = dir.appendingPathComponent("First.wav"), second = dir.appendingPathComponent("Second.wav")
        try makeTone(at: first)
        try makeTone(at: second, seconds: 2)
        let held = Locked<[HeldTrim]>([])
        let model = makeModelWithHeldSaves(held)
        addTeardownBlock { await model.close() }
        try await open(first, in: model)
        model.save()
        try await waitUntil("the first save starts") { held.value.count == 1 }

        try await open(second, in: model)
        try held.value.element(at: 0).finish.resume(returning: TrimAudioResult(url: dir.appendingPathComponent("First (Trimmed).mp3"), copiedAsIs: false))
        try await pause(for: .milliseconds(50), because: "the old save's result would land on a later main-actor turn")

        XCTAssertEqual(model.saveState, .idle)
    }

    @MainActor
    func testSaveMakesItsFolderUnderTheGivenParent() async throws {
        let tone = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: tone)
        let held = Locked<[HeldTrim]>([])
        let model = makeModelWithHeldSaves(held)
        addTeardownBlock { await model.close() }
        try await open(tone, in: model)

        model.save()
        try await waitUntil("the save starts") { held.value.count == 1 }

        let folder = try XCTUnwrap(held.value.first).folder
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertTrue(folder.lastPathComponent.hasPrefix(TrimAudioModel.outputFolderName))
        try XCTUnwrap(held.value.first).finish.resume(throwing: CancellationError())
        try await waitUntil("the save ends") { model.saveState == .idle }
    }

    @MainActor
    func testClosingTheFileStopsTheWaveformDecode() async throws {
        let tone = dir.appendingPathComponent("Tone.wav")
        try makeTone(at: tone)
        let started = Locked(false), cancelled = Locked(false)
        let model = TrimAudioModel(outputParent: dir, decodePeaks: { _, _ in
            started.set(true)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (decode: CheckedContinuation<[Float], Error>) in
                    DispatchQueue.global().async {
                        while !cancelled.value { usleep(1000) }
                        decode.resume(throwing: CancellationError())
                    }
                }
            } onCancel: {
                cancelled.set(true)
            }
        })
        addTeardownBlock { cancelled.set(true) }
        model.load(tone)
        try await waitUntil(timeout: .seconds(30), "the waveform decode starts") { started.value }

        model.close()

        try await waitUntil("the decode is told to stop") { cancelled.value }
    }

    func testMissingEncoderIsReported() async throws {
        let job = TrimAudioJob(source: dir.appendingPathComponent("Tone.wav"), start: 0, end: 1, sample: .init(bitDepth: 16), settings: .init())
        do {
            _ = try await AudioTrimmer.trim(job, into: dir, ffmpeg: nil) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TrimAudioError, .noEncoder)
        }
    }

    // MARK: Helpers

    private func makeTone(at url: URL, seconds: Double? = nil) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(sampleRate * (seconds ?? toneSeconds))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for i in 0..<Int(frames) { data[i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate)) }
        }
        try file.write(from: buffer)
    }

    private func mono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData?.pointee)
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    private func rms(_ samples: [Float], from start: Double, seconds: Double, rate: Double) -> Float {
        let lower = max(Int(start * rate), 0), upper = min(Int((start + seconds) * rate), samples.count)
        guard upper > lower else { return 0 }
        let slice = samples[lower..<upper]
        return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
    }
}
