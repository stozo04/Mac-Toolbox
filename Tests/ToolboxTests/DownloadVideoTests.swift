import XCTest
@testable import Toolbox

final class DownloadVideoTests: XCTestCase {
    private let url = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let folder = URL(fileURLWithPath: "/tmp/out")

    private func args(_ o: DownloadOptions, ffmpeg: Bool = true, choice: FormatChoice? = nil,
                      source: YtDlpCommand.Source? = nil, js: JSRuntime? = nil) -> [String] {
        YtDlpCommand.arguments(source: source ?? .link(url), options: o, choice: choice, folder: folder,
                               hasFFmpeg: ffmpeg,
                               ffmpegDirectory: ffmpeg ? URL(fileURLWithPath: "/opt/homebrew/bin") : nil,
                               jsRuntime: js)
    }

    private func value(after flag: String, in a: [String]) -> String? {
        a.firstIndex(of: flag).map { a[$0 + 1] }
    }

    func testBestQualityDefaultsToHighestResolutionThenFrameRate() {
        XCTAssertFalse(DownloadOptions().mostCompatible)
        XCTAssertEqual(DownloadOptions().format, .best)
        let a = args(DownloadOptions())
        XCTAssertEqual(value(after: "-S", in: a), "res,fps")
        XCTAssertEqual(value(after: "--merge-output-format", in: a), "mp4")
        XCTAssertEqual(a.last, url.absoluteString)
    }

    func testMostCompatibleSortsH264First() {
        let a = args(DownloadOptions(format: .best, mostCompatible: true))
        XCTAssertEqual(value(after: "-S", in: a), "vcodec:h264,res,fps,acodec:aac")
    }

    func testResolutionCap() {
        XCTAssertEqual(value(after: "-S", in: args(DownloadOptions(format: .p720))), "res:720,fps")
    }

    func testChosenFormatIsDownloadedFromTheProbe() {
        let info = URL(fileURLWithPath: "/tmp/x.info.json")
        let choice = FormatChoice(formatSpec: "701+251", width: 3840, height: 2160, fps: 60, codec: .av1, playsInQuickTime: true)
        let a = args(DownloadOptions(), choice: choice, source: .infoJSON(info))
        XCTAssertEqual(value(after: "-f", in: a), "701+251")
        XCTAssertEqual(value(after: "--load-info-json", in: a), info.path)
        XCTAssertFalse(a.contains("-S"))
        XCTAssertFalse(a.contains(url.absoluteString))
    }

    func testJSRuntimeIsPassed() {
        let deno = JSRuntime(name: "deno", path: URL(fileURLWithPath: "/opt/homebrew/bin/deno"))
        XCTAssertEqual(value(after: "--js-runtimes", in: args(DownloadOptions(), js: deno)), "deno:/opt/homebrew/bin/deno")
        let probe = YtDlpCommand.probeArguments(url: url, jsRuntime: deno)
        XCTAssertEqual(Array(probe.prefix(3)), ["-J", "--no-playlist", "--no-warnings"])
        XCTAssertEqual(value(after: "--js-runtimes", in: probe), "deno:/opt/homebrew/bin/deno")
        XCTAssertFalse(args(DownloadOptions()).contains("--js-runtimes"))
    }

    func testAudioOnlyExtractsM4A() {
        let a = args(DownloadOptions(format: .audio))
        XCTAssertEqual(value(after: "--audio-format", in: a), "m4a")
        XCTAssertFalse(a.contains("-S"))
    }

    func testWithoutFFmpegUsesSingleFileFormats() {
        let a = args(DownloadOptions(format: .p1080), ffmpeg: false)
        XCTAssertEqual(value(after: "-f", in: a), "b[height<=1080][ext=mp4]/b[height<=1080]/b")
        XCTAssertFalse(a.contains("--ffmpeg-location"))
    }

    func testParsesProgress() {
        XCTAssertEqual(YtDlpCommand.parse("TBX_PROGRESS|500|1000|NA|2048.5|12"),
                       .event(.progress(fraction: 0.5, bytesPerSecond: 2048.5, etaSeconds: 12)))
        // Falls back to the estimate, and tolerates missing values.
        XCTAssertEqual(YtDlpCommand.parse("TBX_PROGRESS|250|NA|1000|NA|NA"),
                       .event(.progress(fraction: 0.25, bytesPerSecond: nil, etaSeconds: nil)))
        XCTAssertEqual(YtDlpCommand.parse("TBX_PROGRESS|10|NA|NA|NA|NA"),
                       .event(.progress(fraction: nil, bytesPerSecond: nil, etaSeconds: nil)))
    }

    func testParsesTitleAndFile() {
        XCTAssertEqual(YtDlpCommand.parse("TBX_TITLE|A | B"), .event(.title("A | B")))
        XCTAssertEqual(YtDlpCommand.parse("TBX_FILE|/tmp/a.mp4"), .file("/tmp/a.mp4"))
        XCTAssertEqual(YtDlpCommand.parse("[download] 5%"), .other)
    }

    func testFriendlyError() {
        XCTAssertEqual(YtDlpCommand.friendlyError(from: "ERROR: [youtube] abc123: Video unavailable\n"),
                       "Video unavailable")
        XCTAssertEqual(YtDlpCommand.friendlyError(from: "ERROR: Unsupported URL: https://x.com/a"),
                       "Unsupported URL: https://x.com/a")
        XCTAssertEqual(YtDlpCommand.friendlyError(from: ""), "The download failed.")
    }

    func testLinkExtraction() {
        let text = "https://youtu.be/a\nhttps://www.tiktok.com/@u/video/1  https://youtu.be/a, nope ftp://x.y/z"
        XCTAssertEqual(DownloadVideoModel.links(in: text).map(\.absoluteString),
                       ["https://youtu.be/a", "https://www.tiktok.com/@u/video/1"])
    }

    func testYouTubeAlertOnlyForYouTubeHosts() {
        XCTAssertTrue(DownloadAlert.isYouTube(URL(string: "https://www.youtube.com/watch?v=a")!))
        XCTAssertTrue(DownloadAlert.isYouTube(URL(string: "https://youtu.be/a")!))
        XCTAssertFalse(DownloadAlert.isYouTube(URL(string: "https://www.tiktok.com/@u/video/1")!))
        XCTAssertFalse(DownloadAlert.isYouTube(URL(string: "https://notyoutube.com/a")!))
    }

    @MainActor func testModelRunsQueueAndReportsFailures() async throws {
        struct Fake: Downloader {
            func download(url: URL, options: DownloadOptions, into folder: URL,
                          onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
                onEvent(.title("T"))
                if url.host == "bad.example.com" { throw DownloadError.failed("Video unavailable") }
                return folder.appendingPathComponent("ok.mp4")
            }
        }
        let model = DownloadVideoModel(downloader: Fake(), saveFolder: FileManager.default.temporaryDirectory)
        model.linkText = "https://good.example.com/1 https://bad.example.com/2"
        model.start()
        while model.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.items.count, 2)
        guard case .done = model.items[0].state else { return XCTFail("first should be done") }
        XCTAssertEqual(model.items[1].state, .failed("Video unavailable"))
        XCTAssertEqual(model.finishedCount, 1)
    }

    @MainActor func testClearTrashesOnlyFinishedDownloads() async throws {
        struct Fake: Downloader {
            func download(url: URL, options: DownloadOptions, into folder: URL,
                          onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
                if url.host == "bad.example.com" { throw DownloadError.failed("Video unavailable") }
                return folder.appendingPathComponent("ok.mp4")
            }
        }
        final class Trashed: @unchecked Sendable { var files: [URL] = [] }
        let trashed = Trashed()
        let folder = URL(fileURLWithPath: "/tmp/never-touched")
        let model = DownloadVideoModel(downloader: Fake(), saveFolder: folder, trash: { trashed.files.append($0) })
        model.linkText = "https://good.example.com/1 https://bad.example.com/2"
        model.start()
        while model.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }

        model.clearFinished()

        XCTAssertEqual(trashed.files, [folder.appendingPathComponent("ok.mp4")])
        XCTAssertTrue(model.items.isEmpty)
    }
}

final class YtDlpDownloaderTests: XCTestCase {
    func testLargeProbeDoesNotHangAndTheChosenFormatIsDownloaded() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbx-fake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let filler = (0..<3000).map { #"{"format_id":"f\#($0)","vcodec":"avc1","acodec":"none","width":256,"height":144,"fps":30}"# }
        let best = #"{"format_id":"top","vcodec":"hvc1","acodec":"mp4a.40.2","width":1080,"height":1920,"fps":60}"#
        let probe = dir.appendingPathComponent("probe.json")
        let json: String = #"{"formats":["# + (filler + [best]).joined(separator: ",") + "]}"
        try Data(json.utf8).write(to: probe)
        XCTAssertGreaterThan(try Data(contentsOf: probe).count, 200_000)

        let saved = dir.appendingPathComponent("out.mp4")
        let argsLog = dir.appendingPathComponent("args.txt")
        let script = dir.appendingPathComponent("yt-dlp")
        try """
        #!/bin/sh
        if [ "$1" = "-J" ]; then cat '\(probe.path)'; exit 0; fi
        echo "$@" > '\(argsLog.path)'
        touch '\(saved.path)'
        echo 'TBX_FILE|\(saved.path)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let downloader = YtDlpDownloader(executable: script, ffmpeg: URL(fileURLWithPath: "/usr/bin/true"))
        let events = EventLog()
        let file = try await downloader.download(url: URL(string: "https://example.com/v")!, options: DownloadOptions(),
                                                 into: dir) { events.add($0) }
        XCTAssertEqual(file.path, saved.path)
        XCTAssertEqual(events.choice?.formatSpec, "top")
        let args = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(args.contains("-f top"), args)
        XCTAssertTrue(args.contains("--load-info-json"), args)
    }
}

/// Hits the network. Run with: TOOLBOX_YTDLP=/path/to/yt-dlp TOOLBOX_TEST_URL=<link> [TOOLBOX_TEST_FORMAT="Best Quality"] [TOOLBOX_TEST_MIN_SHORT_SIDE=1080] swift test --filter Integration
final class DownloadVideoIntegrationTests: XCTestCase {
    func testRealDownload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let link = env["TOOLBOX_TEST_URL"], let url = URL(string: link),
              let downloader = YtDlpLocator.makeDownloader() else {
            throw XCTSkip("Set TOOLBOX_YTDLP and TOOLBOX_TEST_URL to run")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let format = DownloadFormat(rawValue: env["TOOLBOX_TEST_FORMAT"] ?? "") ?? .p720
        let events = EventLog()
        let file = try await downloader.download(url: url, options: DownloadOptions(format: format), into: dir) {
            events.add($0)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 10_000)
        XCTAssertEqual(file.pathExtension, format == .audio ? "m4a" : "mp4")
        XCTAssertGreaterThan(events.count, 0)
        if let minimum = env["TOOLBOX_TEST_MIN_SHORT_SIDE"].flatMap(Int.init) {
            let chosen = try XCTUnwrap(events.choice, "no format was chosen")
            XCTAssertGreaterThanOrEqual(min(chosen.width ?? 0, chosen.height ?? 0), minimum, chosen.summary)
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []
    func add(_ e: DownloadEvent) { lock.lock(); events.append(e); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    var choice: FormatChoice? {
        lock.lock(); defer { lock.unlock() }
        return events.lazy.compactMap { if case .chosen(let c) = $0 { c } else { nil } }.first
    }
}
