import AVFoundation
import XCTest
@testable import Toolbox

final class BurnInSubtitlesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnin-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Parsing

    func testParsesSRTWithBOMWindowsLineEndingsAndMarkup() {
        let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Hello</i> &amp; welcome\r\nsecond line\r\n\r\n2\r\n00:01:02,250 --> 00:01:04,000\r\n{\\an8}Up top\r\n"
        XCTAssertEqual(SubtitleFile.parse(srt), [
            SubtitleCue(start: 1, end: 3.5, text: "Hello & welcome\nsecond line"),
            SubtitleCue(start: 62.25, end: 64, text: "Up top"),
        ])
    }

    func testParsesWebVTTWithHeaderNotesIdentifiersAndShortTimes() {
        let vtt = """
        WEBVTT - demo

        NOTE a comment
        that spans lines

        STYLE
        ::cue { color: red }

        intro
        00:01.000 --> 00:02.500 align:start position:10%
        <v Roger>First <c.yellow>cue</c>

        01:00:00.000 --> 01:00:01.000
        An hour in <00:00:00.500>here
        """
        XCTAssertEqual(SubtitleFile.parse(vtt), [
            SubtitleCue(start: 1, end: 2.5, text: "First cue"),
            SubtitleCue(start: 3600, end: 3601, text: "An hour in here"),
        ])
    }

    func testSkipsBrokenBlocksAndSortsByStart() {
        let text = "2\n00:00:05,000 --> 00:00:06,000\nLater\n\nnonsense\n\n1\n00:00:01,000 --> 00:00:00,500\nBackwards\n\n3\n00:00:02,000 --> 00:00:03,000\nSooner\n"
        XCTAssertEqual(SubtitleFile.parse(text).map(\.text), ["Sooner", "Later"])
        XCTAssertEqual(SubtitleFile.parse("hello"), [])
    }

    func testTimeFormats() {
        XCTAssertEqual(SubtitleFile.time("01:02:03,500"), 3723.5)
        XCTAssertEqual(SubtitleFile.time("02:03.5"), 123.5)
        XCTAssertEqual(SubtitleFile.time("3.25"), 3.25)
        XCTAssertNil(SubtitleFile.time("abc"))
        XCTAssertNil(SubtitleFile.time("1:2:3:4"))
    }

    func testWritesSRTThatReadsBackTheSame() {
        let cues = [SubtitleCue(start: 0.5, end: 2, text: "One"), SubtitleCue(start: 3723.456, end: 3725, text: "Two\nlines")]
        let text = SubtitleFile.srt(cues)
        XCTAssertTrue(text.hasPrefix("1\n00:00:00,500 --> 00:00:02,000\nOne\n"))
        XCTAssertTrue(text.contains("01:02:03,456 --> 01:02:05,000"))
        XCTAssertEqual(SubtitleFile.parse(text), cues)
    }

    func testLoadsAFileAndReportsOnesWithoutCaptions() throws {
        let good = dir.appendingPathComponent("a.srt"), bad = dir.appendingPathComponent("b.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: good, atomically: true, encoding: .utf8)
        try "just words".write(to: bad, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SubtitleFile.load(good).count, 1)
        XCTAssertThrowsError(try SubtitleFile.load(bad))
        XCTAssertThrowsError(try SubtitleFile.load(dir.appendingPathComponent("missing.srt")))
    }

    func testLoadsUTF16AndLatin1Files() throws {
        let body = "1\n00:00:01,000 --> 00:00:02,000\nCafé ñ\n"
        let utf16 = dir.appendingPathComponent("u16.srt"), latin = dir.appendingPathComponent("l1.srt")
        try body.data(using: .utf16)!.write(to: utf16)
        try body.data(using: .isoLatin1)!.write(to: latin)
        XCTAssertEqual(try SubtitleFile.load(utf16).first?.text, "Café ñ")
        XCTAssertEqual(try SubtitleFile.load(latin).first?.text, "Café ñ")
    }

    func testFindsASubtitleFileWithTheVideosName() throws {
        let video = dir.appendingPathComponent("Trip.MP4")
        for name in ["Trip.MP4", "trip.VTT", "Other.srt"] { try Data().write(to: dir.appendingPathComponent(name)) }
        XCTAssertEqual(SubtitleFile.sidecar(for: video)?.lastPathComponent, "trip.VTT")
        try Data().write(to: dir.appendingPathComponent("Trip.srt"))
        XCTAssertEqual(SubtitleFile.sidecar(for: video)?.lastPathComponent, "Trip.srt", "SRT wins over VTT")
        XCTAssertNil(SubtitleFile.sidecar(for: dir.appendingPathComponent("Nothing.mp4")))
    }

    // MARK: Cues from speech

    private func words(_ spec: [(String, Double, Double)]) -> [TimedWord] { spec.map { TimedWord(text: $0.0, start: $0.1, duration: $0.2) } }

    func testBreaksCuesAtSentenceEndsAndPauses() {
        let cues = CueBuilder.cues(from: words([("Hello", 0, 0.4), ("there.", 0.5, 0.5), ("How", 1.25, 0.5), ("are", 1.75, 0.25), ("you", 4.0, 0.5)]))
        XCTAssertEqual(cues, [
            SubtitleCue(start: 0, end: 1, text: "Hello there."),
            SubtitleCue(start: 1.25, end: 2, text: "How are"),
            SubtitleCue(start: 4, end: 4.5, text: "you"),
        ])
    }

    func testBreaksLongRunsByLengthAndDuration() {
        let long = (0..<20).map { TimedWord(text: "word\($0)", start: Double($0) * 0.3, duration: 0.25) }
        let cues = CueBuilder.cues(from: words([]) + long)
        XCTAssertGreaterThan(cues.count, 1)
        XCTAssertTrue(cues.allSatisfy { $0.text.count <= CueBuilder.maxCharacters })
        XCTAssertEqual(cues.map(\.text).joined(separator: " "), long.map(\.text).joined(separator: " "), "no word lost")
        let slow = (0..<5).map { TimedWord(text: "w\($0)", start: Double($0) * 2, duration: 1.9) }
        XCTAssertTrue(CueBuilder.cues(from: slow).allSatisfy { $0.end - $0.start <= CueBuilder.maxSeconds + 2 })
        XCTAssertGreaterThan(CueBuilder.cues(from: slow).count, 1)
    }

    func testNoWordsMakeNoCues() {
        XCTAssertEqual(CueBuilder.cues(from: []), [])
        XCTAssertEqual(CueBuilder.cues(from: words([(" ", 0, 1)])), [])
    }

    // MARK: Drawing

    func testCaptionPlacementTopAndBottomAndCentre() throws {
        let video = CGSize(width: 1280, height: 720)
        let bottom = try XCTUnwrap(CaptionRenderer.render("Hello", style: CaptionStyle(), videoSize: video))
        var top = CaptionStyle(); top.position = .top
        let up = try XCTUnwrap(CaptionRenderer.render("Hello", style: top, videoSize: video))
        XCTAssertEqual(bottom.frame.midX, 640, accuracy: 1)
        XCTAssertEqual(bottom.frame.minY, 36, accuracy: 1, "5% above the bottom edge")
        XCTAssertEqual(up.frame.maxY, 720 - 36, accuracy: 1, "5% below the top edge")
        XCTAssertGreaterThan(up.frame.minY, 360)
    }

    func testBiggerTextAndWrappingMakeTallerCaptions() throws {
        let video = CGSize(width: 1280, height: 720)
        func height(_ text: String, _ size: CaptionStyle.Size) throws -> CGFloat {
            var style = CaptionStyle(); style.size = size
            return try XCTUnwrap(CaptionRenderer.render(text, style: style, videoSize: video)).frame.height
        }
        XCTAssertLessThan(try height("Hi", .small), try height("Hi", .medium))
        XCTAssertLessThan(try height("Hi", .medium), try height("Hi", .large))
        let long = String(repeating: "wrapping words ", count: 12)
        XCTAssertGreaterThan(try height(long, .medium), try height("Hi", .medium) * 2)
        let wide = try XCTUnwrap(CaptionRenderer.render(long, style: CaptionStyle(), videoSize: video))
        XCTAssertLessThanOrEqual(wide.frame.width, 1280 * CaptionRenderer.maxWidthShare + 1)
    }

    func testBlackBoxLookDrawsADarkBoxBehindTheText() throws {
        var style = CaptionStyle(); style.look = .box
        let boxed = try XCTUnwrap(CaptionRenderer.render("Hello", style: style, videoSize: CGSize(width: 1280, height: 720)))
        let corner = pixel(boxed.image, x: 12, y: 12)
        XCTAssertGreaterThan(corner.a, 150, "the box is mostly opaque at its corner")
        XCTAssertLessThan(corner.r, 20)
        let plain = try XCTUnwrap(CaptionRenderer.render("Hello", style: CaptionStyle(), videoSize: CGSize(width: 1280, height: 720)))
        XCTAssertEqual(pixel(plain.image, x: 2, y: 2).a, 0, "shadow look has nothing behind the text")
    }

    func testEmptyTextDrawsNothing() {
        XCTAssertNil(CaptionRenderer.render("", style: CaptionStyle(), videoSize: CGSize(width: 640, height: 360)))
    }

    func testVisibleCuesAreCutAtTheEndOfTheVideo() {
        let cues = [SubtitleCue(start: 1, end: 2, text: "a"), SubtitleCue(start: 9, end: 12, text: "b"), SubtitleCue(start: 20, end: 21, text: "c")]
        XCTAssertEqual(SubtitleBurner.visible(cues, duration: 10), [cues[0], SubtitleCue(start: 9, end: 10, text: "b")])
    }

    // MARK: Burning

    func testCaptionsAppearOnlyWhileTheirCueShows() async throws {
        let source = dir.appendingPathComponent("Clip.mov")
        try await makeVideo(at: source, seconds: 4)
        let before = try Data(contentsOf: source)
        let cues = [SubtitleCue(start: 1, end: 2, text: "HELLO WORLD"), SubtitleCue(start: 3, end: 3.5, text: "SECOND")]

        let result = try await SubtitleBurner.burn(source: source, cues: cues, style: CaptionStyle(), into: dir) { _ in }

        XCTAssertEqual(result.url.lastPathComponent, "Clip (Subtitled).mov")
        XCTAssertEqual(result.cueCount, 2)
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is untouched")
        let length = try await duration(of: result.url)
        XCTAssertEqual(length, 4, accuracy: 0.2)

        // Compare frames with the one before any caption: only the band holding the caption may change.
        let out = AVURLAsset(url: result.url)
        let bare = try await frame(out, at: 0.4)
        let first = try await changes(from: bare, to: frame(out, at: 1.5))
        let between = try await changes(from: bare, to: frame(out, at: 2.5))
        let second = try await changes(from: bare, to: frame(out, at: 3.2))
        let after = try await changes(from: bare, to: frame(out, at: 3.8))
        XCTAssertGreaterThan(first.bottom, 50, "caption near the bottom while the cue shows")
        XCTAssertEqual(first.top, 0)
        XCTAssertEqual(between.bottom, 0, "gone once the cue ends")
        XCTAssertGreaterThan(second.bottom, 20, "the next cue shows")
        XCTAssertEqual(after.bottom, 0)
        XCTAssertLessThan(abs(first.bottom - second.bottom), first.bottom, "only one caption at a time")
    }

    func testCaptionAtTheTopAndTheBlackBox() async throws {
        let source = dir.appendingPathComponent("Top.mov")
        try await makeVideo(at: source, seconds: 2)
        var style = CaptionStyle(); style.position = .top; style.look = .box

        let result = try await SubtitleBurner.burn(source: source, cues: [SubtitleCue(start: 1, end: 5, text: "TOP")], style: style, into: dir) { _ in }

        let out = AVURLAsset(url: result.url)
        let changed = try await changes(from: frame(out, at: 0.4), to: frame(out, at: 1.5))
        XCTAssertGreaterThan(changed.top, 100, "the black box covers a wide patch at the top")
        XCTAssertEqual(changed.bottom, 0)
    }

    func testCaptionsKeepAudioAndOrientation() async throws {
        let source = dir.appendingPathComponent("Portrait.mov")
        try await makeVideo(at: source, seconds: 2, size: CGSize(width: 320, height: 180), rotation: .pi / 2)
        let result = try await SubtitleBurner.burn(source: source, cues: [SubtitleCue(start: 0, end: 2, text: "Hi")], style: CaptionStyle(), into: dir) { _ in }
        let track = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)[0]
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let size = natural.applying(transform)
        XCTAssertEqual([abs(size.width), abs(size.height)], [180, 320], "still upright")
    }

    func testRefusesCuesAfterTheEndAndFilesWithoutVideo() async throws {
        let source = dir.appendingPathComponent("Short.mov")
        try await makeVideo(at: source, seconds: 1)
        do {
            _ = try await SubtitleBurner.burn(source: source, cues: [SubtitleCue(start: 30, end: 31, text: "late")], style: CaptionStyle(), into: dir) { _ in }
            XCTFail("no caption falls inside the video")
        } catch BurnError.nothingToShow {}
        let text = dir.appendingPathComponent("a.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)
        do {
            _ = try await SubtitleBurner.burn(source: text, cues: [SubtitleCue(start: 0, end: 1, text: "x")], style: CaptionStyle(), into: dir) { _ in }
            XCTFail("a text file has no video")
        } catch {}
    }

    // MARK: Helpers

    private func duration(of url: URL) async throws -> Double { try await AVURLAsset(url: url).load(.duration).seconds }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
    }

    private func frame(_ asset: AVAsset, at seconds: Double) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (data, image.width, image.height)
    }

    /// How many pixels differ in the top and the bottom fifth of the frame.
    private func changes(from a: (pixels: [UInt8], width: Int, height: Int), to b: (pixels: [UInt8], width: Int, height: Int)) -> (top: Int, bottom: Int) {
        func count(rows: Range<Int>) -> Int {
            var n = 0
            for row in rows { for col in 0..<a.width {
                let i = (row * a.width + col) * 4
                if abs(Int(a.pixels[i]) - Int(b.pixels[i])) > 40 || abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])) > 40 { n += 1 }
            } }
            return n
        }
        let fifth = a.height / 5
        return (count(rows: 0..<fifth), count(rows: (a.height - fifth)..<a.height))
    }

    private func makeVideo(at url: URL, seconds: Int, size: CGSize = CGSize(width: 320, height: 180), rotation: Double = 0) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)])
        input.transform = CGAffineTransform(rotationAngle: rotation)
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
            memset(CVPixelBufferGetBaseAddress(b), 40, CVPixelBufferGetDataSize(b))  // dark grey
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}

// MARK: Queue and speech

@MainActor final class BurnInSubtitlesModelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("burnin-model-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func video(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testAVideoIsReadyOnlyWithASubtitleFileInFileMode() throws {
        let plain = try video("Plain.mov"), named = try video("Named.mov")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: dir.appendingPathComponent("Named.srt"), atomically: true, encoding: .utf8)
        let model = BurnInSubtitlesModel()
        model.add([plain, named, plain])

        XCTAssertEqual(model.items.count, 2, "no duplicates")
        XCTAssertFalse(model.isReady(model.items[0]), "no subtitles for Plain")
        XCTAssertTrue(model.isReady(model.items[1]), "Named.srt is picked up")
        XCTAssertEqual(model.subtitleFile(for: model.items[1])?.lastPathComponent, "Named.srt")

        let shared = dir.appendingPathComponent("Shared.vtt")
        try "WEBVTT\n\n00:01.000 --> 00:02.000\nHi\n".write(to: shared, atomically: true, encoding: .utf8)
        model.setSubtitleFile(shared)
        XCTAssertTrue(model.isReady(model.items[0]), "the chosen file covers videos without their own")
        XCTAssertEqual(model.subtitleFile(for: model.items[1])?.lastPathComponent, "Named.srt", "a file beside the video wins")
        XCTAssertTrue(model.hasRunnable)
    }

    func testRejectsASubtitleFileWithNoCaptions() throws {
        let bad = dir.appendingPathComponent("bad.srt")
        try "nothing here".write(to: bad, atomically: true, encoding: .utf8)
        let model = BurnInSubtitlesModel()
        model.setSubtitleFile(bad)
        XCTAssertNil(model.chosenFile)
        XCTAssertNotNil(model.notice)
    }

    func testTranscribeModeNeedsNoSubtitleFile() throws {
        let model = BurnInSubtitlesModel()
        model.add([try video("Talk.mov")])
        XCTAssertFalse(model.hasRunnable)
        model.source = .transcribe
        XCTAssertTrue(model.hasRunnable)
    }

    func testSavesTheTranscriptAsSRTBesideTheOutputWithoutClobbering() throws {
        let cues = [SubtitleCue(start: 1, end: 2, text: "Hi")]
        let video = dir.appendingPathComponent("Talk.mov")
        try BurnInSubtitlesModel.writeSRT(cues, for: video, into: dir)
        try BurnInSubtitlesModel.writeSRT(cues, for: video, into: dir)
        XCTAssertEqual(try SubtitleFile.load(dir.appendingPathComponent("Talk.srt")), cues)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Talk 2.srt").path))
    }

    func testSpeechPermissionIsOnlyAskedForBundlesThatDescribeWhy() throws {
        func bundle(_ name: String, _ extra: [String: Any]) throws -> Bundle {  // a bundle keeps its Info.plist, so each case gets its own
            let contents = dir.appendingPathComponent("\(name).app/Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "test.\(name)", "CFBundlePackageType": "APPL"].merging(extra) { $1 }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            return try XCTUnwrap(Bundle(url: dir.appendingPathComponent("\(name).app")))
        }
        XCTAssertFalse(SpeechTranscriber.canAskForPermission(bundle: try bundle("Without", [:])))
        XCTAssertTrue(SpeechTranscriber.canAskForPermission(bundle: try bundle("With", ["NSSpeechRecognitionUsageDescription": "Because."])))
    }

    func testPicksTheMacsLanguageOtherwiseEnglish() {
        let locales = ["de_DE", "en_US", "fr_FR"].map(Locale.init(identifier:))
        XCTAssertNotNil(SpeechTranscriber.defaultLocale(in: locales))
        XCTAssertNil(SpeechTranscriber.defaultLocale(in: []))
        XCTAssertEqual(SpeechTranscriber.defaultLocale(in: [Locale(identifier: "ja_JP"), Locale(identifier: "en_US")])?.identifier.prefix(2).description == "en"
                       || Locale.current.language.languageCode?.identifier == "ja", true)
    }
}
