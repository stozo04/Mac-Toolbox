import XCTest
@testable import Toolbox

final class FormatPickerTests: XCTestCase {
    private func formats(_ json: String) throws -> [StreamFormat] {
        try XCTUnwrap(JSONDecoder().decode(VideoInfo.self, from: Data(json.utf8)).formats)
    }

    private func pick(_ json: String, _ options: DownloadOptions = DownloadOptions(), ffmpeg: Bool = true,
                      av1: Bool = true) throws -> FormatChoice {
        try XCTUnwrap(FormatPicker.choose(from: formats(json), options: options, hasFFmpeg: ffmpeg, decodesAV1: av1))
    }

    func testYouTubeBestIs4K60AV1WithOriginalNonDRCAudio() throws {
        let c = try pick(Fixtures.youTube4K)
        XCTAssertEqual(c.formatSpec, "701+251")
        XCTAssertEqual(c.height, 2160)
        XCTAssertEqual(c.fps, 60)
        XCTAssertEqual(c.codec, .av1)
        XCTAssertTrue(c.playsInQuickTime)
        XCTAssertEqual(c.summary, "3840×2160 · 60 fps · AV1")
    }

    func testYouTubeWithoutAV1DecodeStillGetsTopResolutionButWarns() throws {
        let c = try pick(Fixtures.youTube4K, av1: false)
        XCTAssertEqual(c.height, 2160)
        XCTAssertFalse(c.playsInQuickTime)
    }

    func testYouTubeMostCompatibleIs1080pH264WithAAC() throws {
        let c = try pick(Fixtures.youTube4K, DownloadOptions(format: .best, mostCompatible: true))
        XCTAssertEqual(c.formatSpec, "299+140")
        XCTAssertEqual(c.codec, .h264)
        XCTAssertEqual(c.height, 1080)
        XCTAssertEqual(c.fps, 60)
    }

    func testYouTube720CapKeepsHighestFrameRate() throws {
        let c = try pick(Fixtures.youTube4K, DownloadOptions(format: .p720))
        XCTAssertEqual(c.height, 720)
        XCTAssertEqual(c.fps, 60)
        XCTAssertEqual(c.codec, .av1)
    }

    func testTikTokBestIsVertical1080pHEVCWithItsOwnSound() throws {
        let c = try pick(Fixtures.tikTok)
        XCTAssertTrue(c.formatSpec.hasPrefix("bytevc1_1080p_"))
        XCTAssertFalse(c.formatSpec.contains("+"))
        XCTAssertEqual(c.width, 1080)
        XCTAssertEqual(c.height, 1920)
        XCTAssertEqual(c.codec, .hevc)
        XCTAssertTrue(c.playsInQuickTime)
    }

    func testTikTokCapUsesShortSideSoVerticalVideosAreNotShrunk() throws {
        let c = try pick(Fixtures.tikTok, DownloadOptions(format: .p1080))
        XCTAssertEqual(c.width, 1080)
        let small = try pick(Fixtures.tikTok, DownloadOptions(format: .p720))
        XCTAssertEqual(small.width, 720)
    }

    func testTikTokMostCompatibleIsH264() throws {
        let c = try pick(Fixtures.tikTok, DownloadOptions(format: .best, mostCompatible: true))
        XCTAssertEqual(c.codec, .h264)
        XCTAssertEqual(c.width, 576)
    }

    func testWithoutFFmpegOnlyFilesWithSoundAreChosen() throws {
        let c = try pick(Fixtures.youTube4K, ffmpeg: false)
        XCTAssertFalse(c.formatSpec.contains("+"))
        XCTAssertEqual(c.formatSpec, "18")
    }

    func testHigherFrameRateWinsAtTheSameResolution() throws {
        let list = [
            StreamFormat(formatID: "a", vcodec: "avc1", acodec: "none", width: 1920, height: 1080, fps: 30, tbr: 9000),
            StreamFormat(formatID: "b", vcodec: "avc1", acodec: "none", width: 1920, height: 1080, fps: 60, tbr: 5000),
            StreamFormat(formatID: "s", vcodec: "none", acodec: "mp4a.40.2", abr: 128),
        ]
        let c = try XCTUnwrap(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertEqual(c.formatSpec, "b+s")
    }

    func testPlayableBeatsHigherFrameRateVP9AtTheSameResolution() throws {
        let list = [
            StreamFormat(formatID: "vp", vcodec: "vp9", acodec: "none", width: 3840, height: 2160, fps: 60),
            StreamFormat(formatID: "hevc", vcodec: "hvc1", acodec: "none", width: 3840, height: 2160, fps: 30),
        ]
        let c = try XCTUnwrap(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertEqual(c.formatSpec, "hevc")
    }

    func testSilentTopVideoWithoutSeparateAudioFallsBackToAVersionWithSound() throws {
        let list = [
            StreamFormat(formatID: "silent4k", vcodec: "avc1", acodec: "none", width: 3840, height: 2160, fps: 30),
            StreamFormat(formatID: "muxed720", vcodec: "avc1", acodec: "mp4a.40.2", width: 1280, height: 720, fps: 30),
        ]
        let c = try XCTUnwrap(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertEqual(c.formatSpec, "muxed720")
        XCTAssertEqual(c.height, 720)
    }

    func testVideoWithUnknownAudioIsPairedWithSeparateAudio() throws {
        let list = [
            StreamFormat(formatID: "hls1080", vcodec: "avc1", width: 1920, height: 1080, fps: 30),
            StreamFormat(formatID: "aud", vcodec: "none", acodec: "mp4a.40.2", abr: 128),
        ]
        let c = try XCTUnwrap(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertEqual(c.formatSpec, "hls1080+aud")
    }

    func testVideoWithUnknownAudioAndNoSeparateAudioIsKept() throws {
        let list = [StreamFormat(formatID: "only", vcodec: "avc1", width: 1920, height: 1080)]
        let c = try XCTUnwrap(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertEqual(c.formatSpec, "only")
    }

    func testNoResolutionInfoFallsBackToYtDlp() {
        let list = [StreamFormat(formatID: "only", vcodec: "h264", acodec: "aac")]
        XCTAssertNil(FormatPicker.choose(from: list, options: DownloadOptions(), hasFFmpeg: true, decodesAV1: true))
        XCTAssertNil(FormatPicker.choose(from: list, options: DownloadOptions(format: .audio), hasFFmpeg: true))
    }

    func testCodecNames() {
        XCTAssertEqual(VideoCodec(ytDlpName: "avc1.64002A"), .h264)
        XCTAssertEqual(VideoCodec(ytDlpName: "bytevc1"), .hevc)
        XCTAssertEqual(VideoCodec(ytDlpName: "h265"), .hevc)
        XCTAssertEqual(VideoCodec(ytDlpName: "av01.0.13M.10"), .av1)
        XCTAssertEqual(VideoCodec(ytDlpName: "vp09.02.51"), .vp9)
        XCTAssertEqual(VideoCodec(ytDlpName: "none"), .unknown)
        XCTAssertEqual(VideoCodec(ytDlpName: nil), .unknown)
    }
}

private enum Fixtures {
    static let youTube4K = #"""
    {"formats":[
    {"format_id":"233","vcodec":"none","ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"234","vcodec":"none","ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"139-drc","vcodec":"none","acodec":"mp4a.40.5","tbr":48.816,"abr":48.816,"ext":"m4a","language_preference":-1,"protocol":"https"},
    {"format_id":"249-drc","vcodec":"none","acodec":"opus","tbr":50.66,"abr":50.66,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"250-drc","vcodec":"none","acodec":"opus","tbr":67.567,"abr":67.567,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"139","vcodec":"none","acodec":"mp4a.40.5","tbr":48.817,"abr":48.817,"ext":"m4a","language_preference":-1,"protocol":"https"},
    {"format_id":"249","vcodec":"none","acodec":"opus","tbr":50.384,"abr":50.384,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"250","vcodec":"none","acodec":"opus","tbr":67.194,"abr":67.194,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"140-drc","vcodec":"none","acodec":"mp4a.40.2","tbr":129.492,"abr":129.492,"ext":"m4a","language_preference":-1,"protocol":"https"},
    {"format_id":"251-drc","vcodec":"none","acodec":"opus","tbr":132.7,"abr":132.7,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"140","vcodec":"none","acodec":"mp4a.40.2","tbr":129.492,"abr":129.492,"ext":"m4a","language_preference":-1,"protocol":"https"},
    {"format_id":"251","vcodec":"none","acodec":"opus","tbr":132.567,"abr":132.567,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"602","vcodec":"vp09.00.10.08","acodec":"none","width":256,"height":144,"fps":15.0,"tbr":94.603,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"269","vcodec":"avc1.4D400C","acodec":"none","width":256,"height":144,"fps":30.0,"tbr":169.48,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"160","vcodec":"avc1.4D400C","acodec":"none","width":256,"height":144,"fps":30,"tbr":67.281,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"603","vcodec":"vp09.00.11.08","acodec":"none","width":256,"height":144,"fps":30.0,"tbr":159.161,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"278","vcodec":"vp9","acodec":"none","width":256,"height":144,"fps":30,"tbr":66.535,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"631","vcodec":"vp09.02.11.10.01.09.16.09.00","acodec":"none","width":256,"height":144,"fps":60.0,"tbr":308.79,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"330","vcodec":"vp9.2","acodec":"none","width":256,"height":144,"fps":60,"tbr":206.055,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"694","vcodec":"av01.0.00M.10.0.110.09.16.09.0","acodec":"none","width":256,"height":144,"fps":60,"tbr":127.423,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"229","vcodec":"avc1.4D4015","acodec":"none","width":426,"height":240,"fps":30.0,"tbr":310.487,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"133","vcodec":"avc1.4D4015","acodec":"none","width":426,"height":240,"fps":30,"tbr":147.8,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"604","vcodec":"vp09.00.20.08","acodec":"none","width":426,"height":240,"fps":30.0,"tbr":256.593,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"242","vcodec":"vp9","acodec":"none","width":426,"height":240,"fps":30,"tbr":132.311,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"632","vcodec":"vp09.02.21.10.01.09.16.09.00","acodec":"none","width":426,"height":240,"fps":60.0,"tbr":579.106,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"331","vcodec":"vp9.2","acodec":"none","width":426,"height":240,"fps":60,"tbr":430.048,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"695","vcodec":"av01.0.01M.10.0.110.09.16.09.0","acodec":"none","width":426,"height":240,"fps":60,"tbr":270.033,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"230","vcodec":"avc1.4D401E","acodec":"none","width":640,"height":360,"fps":30.0,"tbr":801.959,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"134","vcodec":"avc1.4D401E","acodec":"none","width":640,"height":360,"fps":30,"tbr":320.457,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"18","vcodec":"avc1.42001E","acodec":"mp4a.40.2","width":640,"height":360,"fps":30,"tbr":449.43,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"605","vcodec":"vp09.00.21.08","acodec":"none","width":640,"height":360,"fps":30.0,"tbr":619.812,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"243","vcodec":"vp9","acodec":"none","width":640,"height":360,"fps":30,"tbr":306.656,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"633","vcodec":"vp09.02.30.10.01.09.16.09.00","acodec":"none","width":640,"height":360,"fps":60.0,"tbr":1250.516,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"332","vcodec":"vp9.2","acodec":"none","width":640,"height":360,"fps":60,"tbr":936.532,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"696","vcodec":"av01.0.04M.10.0.110.09.16.09.0","acodec":"none","width":640,"height":360,"fps":60,"tbr":563.12,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"231","vcodec":"avc1.4D401F","acodec":"none","width":854,"height":480,"fps":30.0,"tbr":1353.413,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"135","vcodec":"avc1.4D401F","acodec":"none","width":854,"height":480,"fps":30,"tbr":560.67,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"606","vcodec":"vp09.00.30.08","acodec":"none","width":854,"height":480,"fps":30.0,"tbr":982.684,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"244","vcodec":"vp9","acodec":"none","width":854,"height":480,"fps":30,"tbr":505.5,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"634","vcodec":"vp09.02.31.10.01.09.16.09.00","acodec":"none","width":854,"height":480,"fps":60.0,"tbr":2226.126,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"333","vcodec":"vp9.2","acodec":"none","width":854,"height":480,"fps":60,"tbr":1839.081,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"697","vcodec":"av01.0.05M.10.0.110.09.16.09.0","acodec":"none","width":854,"height":480,"fps":60,"tbr":1077.844,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"136","vcodec":"avc1.4D401F","acodec":"none","width":1280,"height":720,"fps":30,"tbr":1448.463,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"247","vcodec":"vp9","acodec":"none","width":1280,"height":720,"fps":30,"tbr":1034.384,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"311","vcodec":"avc1.4D4020","acodec":"none","width":1280,"height":720,"fps":60.0,"tbr":3817.207,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"298","vcodec":"avc1.4D4020","acodec":"none","width":1280,"height":720,"fps":60,"tbr":2402.272,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"612","vcodec":"vp09.00.40.08","acodec":"none","width":1280,"height":720,"fps":60.0,"tbr":3774.673,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"302","vcodec":"vp9","acodec":"none","width":1280,"height":720,"fps":60,"tbr":1643.161,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"635","vcodec":"vp09.02.40.10.01.09.16.09.00","acodec":"none","width":1280,"height":720,"fps":60.0,"tbr":4896.993,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"334","vcodec":"vp9.2","acodec":"none","width":1280,"height":720,"fps":60,"tbr":4290.556,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"698","vcodec":"av01.0.08M.10.0.110.09.16.09.0","acodec":"none","width":1280,"height":720,"fps":60,"tbr":3163.518,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"312","vcodec":"avc1.64002A","acodec":"none","width":1920,"height":1080,"fps":60.0,"tbr":6321.284,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"299","vcodec":"avc1.64002A","acodec":"none","width":1920,"height":1080,"fps":60,"tbr":4230.996,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"617","vcodec":"vp09.00.41.08","acodec":"none","width":1920,"height":1080,"fps":60.0,"tbr":7689.974,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"303","vcodec":"vp9","acodec":"none","width":1920,"height":1080,"fps":60,"tbr":3081.815,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"636","vcodec":"vp09.02.41.10.01.09.16.09.00","acodec":"none","width":1920,"height":1080,"fps":60.0,"tbr":8047.925,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"335","vcodec":"vp9.2","acodec":"none","width":1920,"height":1080,"fps":60,"tbr":6691.326,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"699","vcodec":"av01.0.09M.10.0.110.09.16.09.0","acodec":"none","width":1920,"height":1080,"fps":60,"tbr":5101.681,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"623","vcodec":"vp09.00.50.08","acodec":"none","width":2560,"height":1440,"fps":60.0,"tbr":14408.466,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"308","vcodec":"vp9","acodec":"none","width":2560,"height":1440,"fps":60,"tbr":9371.701,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"639","vcodec":"vp09.02.50.10.01.09.16.09.00","acodec":"none","width":2560,"height":1440,"fps":60.0,"tbr":18122.329,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"336","vcodec":"vp9.2","acodec":"none","width":2560,"height":1440,"fps":60,"tbr":16219.428,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"700","vcodec":"av01.0.12M.10.0.110.09.16.09.0","acodec":"none","width":2560,"height":1440,"fps":60,"tbr":13983.203,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"},
    {"format_id":"628","vcodec":"vp09.00.51.08","acodec":"none","width":3840,"height":2160,"fps":60.0,"tbr":28033.687,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"315","vcodec":"vp9","acodec":"none","width":3840,"height":2160,"fps":60,"tbr":24040.546,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"642","vcodec":"vp09.02.51.10.01.09.16.09.00","acodec":"none","width":3840,"height":2160,"fps":60.0,"tbr":32574.395,"abr":0,"ext":"mp4","protocol":"m3u8_native"},
    {"format_id":"337","vcodec":"vp9.2","acodec":"none","width":3840,"height":2160,"fps":60,"tbr":28894.277,"abr":0,"ext":"webm","language_preference":-1,"protocol":"https"},
    {"format_id":"701","vcodec":"av01.0.13M.10.0.110.09.16.09.0","acodec":"none","width":3840,"height":2160,"fps":60,"tbr":24632.098,"abr":0,"ext":"mp4","language_preference":-1,"protocol":"https"}
    ]}
    """#
    static let tikTok = #"""
    {"formats":[
    {"format_id":"audio","vcodec":"none","acodec":"mp3","ext":"mp3","protocol":"https"},
    {"format_id":"download","vcodec":"h264","acodec":"aac","ext":"mp4","protocol":"https"},
    {"format_id":"h264_540p_1407373-0","vcodec":"h264","acodec":"aac","width":576,"height":1024,"tbr":1407,"ext":"mp4","protocol":"https"},
    {"format_id":"h264_540p_1407373-1","vcodec":"h264","acodec":"aac","width":576,"height":1024,"tbr":1407,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_540p_593017-0","vcodec":"h265","acodec":"aac","width":576,"height":1024,"tbr":593,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_540p_593017-1","vcodec":"h265","acodec":"aac","width":576,"height":1024,"tbr":593,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_720p_718701-0","vcodec":"h265","acodec":"aac","width":720,"height":1280,"tbr":718,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_720p_718701-1","vcodec":"h265","acodec":"aac","width":720,"height":1280,"tbr":718,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_1080p_1138892-0","vcodec":"h265","acodec":"aac","width":1080,"height":1920,"tbr":1138,"ext":"mp4","protocol":"https"},
    {"format_id":"bytevc1_1080p_1138892-1","vcodec":"h265","acodec":"aac","width":1080,"height":1920,"tbr":1138,"ext":"mp4","protocol":"https"}
    ]}
    """#
}
