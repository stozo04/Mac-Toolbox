import AVFoundation
import XCTest
@testable import Toolbox

final class MediaInfoTests: XCTestCase {
    func testCodecNamesShowFriendlyNameAndCode() {
        XCTAssertEqual(MediaFormat.codecName(code("avc1")), "H.264 (avc1)")
        XCTAssertEqual(MediaFormat.codecName(code("hvc1")), "HEVC (H.265) (hvc1)")
        XCTAssertEqual(MediaFormat.codecName(code("zzzz")), "zzzz")
    }

    func testDurationAndBitrateWording() {
        XCTAssertEqual(MediaFormat.duration(3.44), "3.4 s")
        XCTAssertEqual(MediaFormat.duration(125.04), "2:05.0")
        XCTAssertEqual(MediaFormat.duration(3725.5), "1:02:05.5")
        XCTAssertEqual(MediaFormat.bitrate(8_240_000), "8.2 Mbps")
        XCTAssertEqual(MediaFormat.bitrate(128_000), "128 kbps")
        XCTAssertEqual(MediaFormat.frameRate(29.97), "29.97 fps")
        XCTAssertEqual(MediaFormat.frameRate(30), "30 fps")
        XCTAssertEqual(MediaFormat.sampleRate(44100), "44.1 kHz")
        XCTAssertEqual(MediaFormat.channels(2), "Stereo")
    }

    func testParsesISO6709Locations() throws {
        let l = try XCTUnwrap(MediaFormat.parseISO6709("+37.3349-122.0090+012.345/"))
        XCTAssertEqual(l.latitude, 37.3349, accuracy: 1e-6)
        XCTAssertEqual(l.longitude, -122.0090, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(l.altitude), 12.345, accuracy: 1e-6)
        XCTAssertNil(MediaFormat.parseISO6709("Cupertino"))
        XCTAssertNil(MediaFormat.parseISO6709("+95.0-122.0/"), "latitude out of range")
        XCTAssertNil(MediaFormat.parseISO6709("+37.3"), "needs both coordinates")
    }

    func testRotationSnapsToQuarterTurns() {
        XCTAssertEqual(MediaInspector.rotation(of: .identity), 0)
        XCTAssertEqual(MediaInspector.rotation(of: CGAffineTransform(rotationAngle: .pi / 2)), 90)
        XCTAssertEqual(MediaInspector.rotation(of: CGAffineTransform(rotationAngle: .pi)), 180)
        XCTAssertEqual(MediaInspector.rotation(of: CGAffineTransform(rotationAngle: -.pi / 2)), 270)
    }

    func testMetadataLabels() {
        XCTAssertEqual(MediaInspector.label(for: "mdta/com.apple.quicktime.make"), "Camera make")
        XCTAssertEqual(MediaInspector.label(for: "mdta/com.apple.quicktime.creationdate"), nil)
        XCTAssertEqual(MediaInspector.label(for: "common/title"), "Title")
        XCTAssertEqual(MediaInspector.label(for: "mdta/com.apple.quicktime.cameraLensModel"), "Camera lens model")
    }

    func testTextReportNeverShowsAFolderAndSaysWhenThereIsNoMetadata() {
        let text = report().text
        XCTAssertTrue(text.contains("File: Clip.mov"))
        XCTAssertTrue(text.contains("Resolution: 1920 × 1080"))
        XCTAssertTrue(text.contains("Sample rate: 48 kHz"))
        XCTAssertTrue(text.contains("No metadata is stored in this file."))
        XCTAssertFalse(text.contains("/"))
    }

    func testJSONIsAnObjectForOneFileAndAnArrayForSeveral() throws {
        let one = try JSONSerialization.jsonObject(with: MediaReport.json([report()]))
        XCTAssertEqual((one as? [String: Any])?["fileName"] as? String, "Clip.mov")
        let many = try JSONSerialization.jsonObject(with: MediaReport.json([report(), report()]))
        XCTAssertEqual((many as? [[String: Any]])?.count, 2)
    }

    func testReadsAGeneratedVideo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediainfo-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sample.mov")
        try await makeVideo(at: url, size: CGSize(width: 320, height: 180), seconds: 2)
        let before = try Data(contentsOf: url)

        let r = try await MediaInspector.inspect(url)

        XCTAssertEqual(r.fileName, "sample.mov")
        XCTAssertEqual(r.duration, 2, accuracy: 0.1)
        XCTAssertEqual(r.sizeBytes, Int64(before.count))
        XCTAssertNotNil(r.overallBitrate)
        let v = try XCTUnwrap(r.videoTracks.first)
        XCTAssertEqual([v.width, v.height], [320, 180])
        XCTAssertTrue(v.codec.hasPrefix("H.264"), v.codec)
        XCTAssertEqual(v.frameRate ?? 0, 30, accuracy: 0.5)
        XCTAssertEqual(v.dynamicRange, "SDR")
        XCTAssertTrue(r.audioTracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before, "the file is only read")
    }

    func testReadsAnAudioOnlyFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediainfo-audio-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true))
        do {  // the WAV header is only finished when the file object goes away
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
            buffer.frameLength = 44100
            try file.write(from: buffer)
        }

        let r = try await MediaInspector.inspect(url)

        XCTAssertTrue(r.videoTracks.isEmpty)
        let a = try XCTUnwrap(r.audioTracks.first)
        XCTAssertEqual(a.sampleRate, 44100)
        XCTAssertEqual(a.channels, 2)
        XCTAssertEqual(a.bitDepth, 16)
        XCTAssertEqual(r.duration, 1, accuracy: 0.05)
    }

    func testReadsLocationDeviceAndOtherMetadata() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediainfo-meta-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.mov")
        let tagged = dir.appendingPathComponent("tagged.mov")
        try await makeVideo(at: plain, size: CGSize(width: 160, height: 90), seconds: 1)

        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            return m
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
        exporter.outputURL = tagged
        exporter.outputFileType = .mov
        exporter.metadata = [item(.quickTimeMetadataMake, "Apple"), item(.quickTimeMetadataModel, "iPhone 17 Pro"),
                             item(.quickTimeMetadataLocationISO6709, "+37.3349-122.0090+012.345/")]
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed, "\(String(describing: exporter.error))")

        let r = try await MediaInspector.inspect(tagged)

        let location = try XCTUnwrap(r.location)
        XCTAssertEqual(location.latitude, 37.3349, accuracy: 1e-6)
        XCTAssertEqual(location.longitude, -122.0090, accuracy: 1e-6)
        XCTAssertTrue(r.metadata.contains(.init(label: "Camera make", value: "Apple")), "\(r.metadata)")
        XCTAssertTrue(r.metadata.contains(.init(label: "Camera model", value: "iPhone 17 Pro")))
        XCTAssertFalse(r.metadata.contains { $0.label.lowercased().contains("location") }, "the location has its own row")
        let untagged = try await MediaInspector.inspect(plain)
        XCTAssertNil(untagged.location)
    }

    func testRefusesAFileThatIsNotMedia() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID()).txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await MediaInspector.inspect(url)
            XCTFail("a text file has no tracks")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    @MainActor func testFolderYieldsOnlyAudioAndVideoButAFileIsAlwaysTried() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mediainfo-folder-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.mov", "b.mp3", "c.txt"] { try Data().write(to: dir.appendingPathComponent(name)) }
        XCTAssertEqual(MediaInfoModel.mediaFiles(in: dir).map(\.lastPathComponent), ["a.mov", "b.mp3"])
        XCTAssertEqual(MediaInfoModel.mediaFiles(in: dir.appendingPathComponent("c.txt")).count, 1)
        XCTAssertEqual(MediaInfoModel.mediaFiles(in: dir.appendingPathComponent("missing.mov")), [])
    }

    // MARK: Helpers

    private func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func report() -> MediaReport {
        MediaReport(fileName: "Clip.mov", sizeBytes: 12_000_000, container: "QuickTime movie", duration: 12.4, overallBitrate: 7_700_000,
                    creationDate: nil,
                    videoTracks: [.init(codec: "H.264 (avc1)", width: 1920, height: 1080, rotation: 0, frameRate: 30, bitrate: 7_500_000,
                                        dynamicRange: "SDR", colorPrimaries: "Rec. 709", bitDepth: nil, language: nil)],
                    audioTracks: [.init(codec: "AAC (mp4a)", sampleRate: 48000, channels: 2, bitDepth: nil, bitrate: 128_000, language: nil)],
                    otherTracks: [], location: nil, metadata: [])
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
