import CoreMedia
import XCTest
@testable import Toolbox

final class RecordScreenTests: XCTestCase {
    func testNativeKeepsSizeButMakesItEven() {
        let s = RecordingGeometry.outputSize(nativePixels: CGSize(width: 3009, height: 1693), resolution: .native)
        XCTAssertEqual(s.width, 3008)
        XCTAssertEqual(s.height, 1692)
    }

    func testScalesDownToHeightKeepingAspect() {
        let s = RecordingGeometry.outputSize(nativePixels: CGSize(width: 3840, height: 2160), resolution: .p1080)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
        let narrow = RecordingGeometry.outputSize(nativePixels: CGSize(width: 3008, height: 1692), resolution: .p720)
        XCTAssertEqual(narrow.height, 720)
        XCTAssertEqual(narrow.width % 2, 0)
    }

    func testNeverScalesUp() {
        let s = RecordingGeometry.outputSize(nativePixels: CGSize(width: 800, height: 600), resolution: .p1440)
        XCTAssertEqual(s.width, 800)
        XCTAssertEqual(s.height, 600)
    }

    func testBitrateIsClamped() {
        XCTAssertEqual(RecordingGeometry.bitrate(width: 100, height: 100, frameRate: 30), 1_000_000)
        XCTAssertEqual(RecordingGeometry.bitrate(width: 7680, height: 4320, frameRate: 60), 40_000_000)
        let hd = RecordingGeometry.bitrate(width: 1920, height: 1080, frameRate: 30)
        XCTAssertTrue((5_000_000...8_000_000).contains(hd))
    }

    func testFileNameAndClock() {
        let name = RecordingGeometry.fileName(date: Date(timeIntervalSince1970: 0), format: .mp4)
        XCTAssertTrue(name.hasPrefix("Toolbox Screen Recording "))
        XCTAssertTrue(name.hasSuffix(".mp4"))
        XCTAssertEqual(RecordingGeometry.clock(0), "0:00")
        XCTAssertEqual(RecordingGeometry.clock(65.9), "1:05")
        XCTAssertEqual(RecordingGeometry.clock(3723), "1:02:03")
    }

    func testSingleSourcePassesThrough() {
        var mixer = AudioMixer(usesSystem: true, usesMicrophone: false)
        XCTAssertEqual(mixer.push([0.1, 0.2], from: .system), [0.1, 0.2])
    }

    func testMixesMicrophoneIntoSystemChunks() {
        var mixer = AudioMixer(usesSystem: true, usesMicrophone: true)
        XCTAssertTrue(mixer.push([0.25, 0.25, 0.25, 0.25], from: .microphone).isEmpty)
        XCTAssertEqual(mixer.push([0.5, 0.5], from: .system), [0.75, 0.75])
        // The rest of the microphone audio is used by the next chunk; missing samples count as silence.
        XCTAssertEqual(mixer.push([0.5, 0.5, 0.5, 0.5], from: .system), [0.75, 0.75, 0.5, 0.5])
    }

    func testMixClampsToFullScale() {
        var mixer = AudioMixer(usesSystem: true, usesMicrophone: true)
        _ = mixer.push([0.9, -0.9], from: .microphone)
        XCTAssertEqual(mixer.push([0.9, -0.9], from: .system), [1, -1])
    }

    func testMicrophonePassesThroughWhenSystemAudioIsQuiet() {
        var mixer = AudioMixer(usesSystem: true, usesMicrophone: true)
        XCTAssertEqual(mixer.push([0.3, 0.3], from: .microphone, systemIsLive: false), [0.3, 0.3])
    }

    func testBufferRoundTrip() {
        let samples: [Float] = [0.1, -0.1, 0.2, -0.2, 0.3, -0.3]
        let buffer = AudioSamples.makeBuffer(samples, at: CMTime(value: 0, timescale: 48_000))
        XCTAssertEqual(buffer.map(CMSampleBufferGetNumSamples), 3)
        XCTAssertEqual(buffer.flatMap(AudioSamples.stereo48k(from:)), samples)
    }

    func testResampleChangesLength() {
        let stereo = [Float](repeating: 0.5, count: 4_410 * 2)
        let out = AudioSamples.resample(stereo, from: 44_100)
        XCTAssertEqual(out.count / 2, 4_800, accuracy: 2)
    }
}
