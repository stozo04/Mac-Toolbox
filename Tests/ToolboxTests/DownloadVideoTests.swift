import XCTest
@testable import Toolbox

final class DownloadVideoTests: XCTestCase {
    private let url = URL(string: "https://www.youtube.com/watch?v=abc")!
    private let folder = URL(fileURLWithPath: "/tmp/out")
    private let partials = URL(fileURLWithPath: "/tmp/partials")

    private func args(_ o: DownloadOptions, ffmpeg: Bool = true, choice: FormatChoice? = nil,
                      source: YtDlpCommand.Source? = nil, js: JSRuntime? = nil) -> [String] {
        YtDlpCommand.arguments(source: source ?? .link(url), options: o, choice: choice, folder: folder,
                               partialsFolder: partials, hasFFmpeg: ffmpeg,
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

    func testUnfinishedFilesGoToThePartialsFolderAndTheSourceStaysLast() {
        let a = args(DownloadOptions())
        XCTAssertEqual(a.indices.filter { a[$0] == "-P" }.map { a[$0 + 1] }, ["/tmp/out", "temp:/tmp/partials"])
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
        try await waitUntil(timeout: .seconds(30), "the downloads have finished") { !model.isRunning }
        XCTAssertEqual(model.items.count, 2)
        guard case .done = try XCTUnwrap(model.items.first).state else { return XCTFail("first should be done") }
        XCTAssertEqual(try model.items.element(at: 1).state, .failed("Video unavailable"))
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
        try await waitUntil(timeout: .seconds(30), "the downloads have finished") { !model.isRunning }

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

final class YtDlpStoppedDownloadTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbx-stopped-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        killProgramsLeftRunning()
        try? FileManager.default.removeItem(at: dir)
    }

    private var partialsLog: URL { dir.appendingPathComponent("partials.txt") }

    private func makeDownloader(afterStartingAFile ending: String) throws -> YtDlpDownloader {
        let script = dir.appendingPathComponent("yt-dlp")
        try """
        #!/bin/sh
        for argument; do case "$argument" in temp:*) partials="${argument#temp:}";; esac; done
        mkdir -p "$partials"
        touch "$partials/video.mp4.part"
        printf '%s' "$partials" > '\(partialsLog.path)'
        echo 'TBX_PROGRESS|1|10|NA|NA|NA'
        \(ending)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return YtDlpDownloader(executable: script, ffmpeg: nil)
    }

    private func partialsFolder() throws -> URL {
        URL(fileURLWithPath: try String(contentsOf: partialsLog, encoding: .utf8))
    }

    func testACancelledDownloadStopsYtDlpAndLeavesNoUnfinishedFiles() async throws {
        let downloader = try makeDownloader(afterStartingAFile: "exec /bin/sleep 30")
        let link = try XCTUnwrap(URL(string: "https://example.com/v"))
        let events = EventLog()
        let folder = try XCTUnwrap(dir)
        let download = Task.detached {
            try await downloader.download(url: link, options: DownloadOptions(format: .audio), into: folder) { events.add($0) }
        }
        try await waitUntil("yt-dlp reports progress") { events.count > 0 }
        let partials = try partialsFolder()
        XCTAssertTrue(FileManager.default.fileExists(atPath: partials.appendingPathComponent("video.mp4.part").path))
        let child = try XCTUnwrap(Shell.livePIDs.first)

        download.cancel()

        guard case .failure(let error) = await download.result else { return XCTFail("a cancelled download returned a file") }
        XCTAssertTrue(error is CancellationError, "threw \(error)")
        XCTAssertFalse(isRunning(child))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partials.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["partials.txt", "yt-dlp"])
    }

    func testAFailedDownloadLeavesNoUnfinishedFiles() async throws {
        let downloader = try makeDownloader(afterStartingAFile: "echo 'ERROR: Video unavailable' >&2; exit 1")
        do {
            _ = try await downloader.download(url: try XCTUnwrap(URL(string: "https://example.com/v")), options: DownloadOptions(format: .audio),
                                              into: dir) { _ in }
            XCTFail("a failed download returned a file")
        } catch {
            XCTAssertEqual(error as? DownloadError, .failed("Video unavailable"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try partialsFolder().path))
    }

    func testTheSavedFileIsReadFromTheWholeOutput() {
        XCTAssertEqual(YtDlpDownloader.savedFile(in: "TBX_TITLE|Café\nTBX_PROGRESS|1|2|3|4|5\nTBX_FILE|/tmp/Café.mp4\n"), "/tmp/Café.mp4")
        XCTAssertNil(YtDlpDownloader.savedFile(in: "TBX_TITLE|Café\n"))
    }

    func testLinesCutAcrossPiecesOfOutputArriveWhole() {
        let seen = Locked<[String]>([])
        let lines = OutputLines { line in seen.update { $0.append(line) } }
        ["TBX_TI", "TLE|One\nTBX_PROGRESS|1|2", "|3|4|5\r\n", "\nunfinished"].forEach(lines.feed)
        XCTAssertEqual(seen.value, ["TBX_TITLE|One", "TBX_PROGRESS|1|2|3|4|5"])
    }
}

final class YtDlpConcurrencyTests: XCTestCase {
    func testManyDownloadsFinishingTogetherAllReturn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbx-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("yt-dlp")
        try """
        #!/bin/sh
        if [ "$1" = "-J" ]; then echo '{"formats":[{"format_id":"v","vcodec":"h264","acodec":"aac","width":720,"height":1280}]}'; exit 0; fi
        for last; do :; done
        name="$(basename "$last" .info.json).mp4"
        touch "\(dir.path)/$name"
        echo "TBX_FILE|\(dir.path)/$name"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let downloader = YtDlpDownloader(executable: script, ffmpeg: URL(fileURLWithPath: "/usr/bin/true"))

        let finished = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<8 {
                group.addTask {
                    for _ in 0..<25 {
                        _ = try await downloader.download(url: try XCTUnwrap(URL(string: "https://example.com/\(i)")),
                                                          options: DownloadOptions(), into: dir) { _ in }
                    }
                    return 25
                }
            }
            return try await group.reduce(0, +)
        }
        XCTAssertEqual(finished, 200)
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
