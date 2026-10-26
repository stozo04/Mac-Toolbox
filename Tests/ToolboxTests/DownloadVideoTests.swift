import XCTest
@testable import Toolbox

final class DownloadVideoTests: XCTestCase {
    private let url = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let folder = URL(fileURLWithPath: "/tmp/out")

    private func args(_ o: DownloadOptions, ffmpeg: Bool = true) -> [String] {
        YtDlpCommand.arguments(url: url, options: o, folder: folder, hasFFmpeg: ffmpeg,
                               ffmpegDirectory: ffmpeg ? URL(fileURLWithPath: "/opt/homebrew/bin") : nil)
    }

    private func value(after flag: String, in a: [String]) -> String? {
        a.firstIndex(of: flag).map { a[$0 + 1] }
    }

    func testBestQualityPrefersH264() {
        let a = args(DownloadOptions(format: .best, preferH264: true))
        XCTAssertEqual(value(after: "-S", in: a), "vcodec:h264,res,acodec:aac")
        XCTAssertEqual(value(after: "--merge-output-format", in: a), "mp4")
        XCTAssertEqual(a.last, url.absoluteString)
    }

    func testResolutionCapWithoutH264() {
        let a = args(DownloadOptions(format: .p720, preferH264: false))
        XCTAssertEqual(value(after: "-S", in: a), "res:720")
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
        let model = DownloadVideoModel(downloader: Fake())
        model.linkText = "https://good.example.com/1 https://bad.example.com/2"
        model.start()
        while model.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.items.count, 2)
        guard case .done = model.items[0].state else { return XCTFail("first should be done") }
        XCTAssertEqual(model.items[1].state, .failed("Video unavailable"))
        XCTAssertEqual(model.finishedCount, 1)
        if let f = model.folder { try? FileManager.default.removeItem(at: f) }
    }
}

/// Hits the network. Run with: TOOLBOX_YTDLP=/path/to/yt-dlp TOOLBOX_TEST_URL=<link> swift test --filter Integration
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
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DownloadEvent] = []
    func add(_ e: DownloadEvent) { lock.lock(); events.append(e); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
}
