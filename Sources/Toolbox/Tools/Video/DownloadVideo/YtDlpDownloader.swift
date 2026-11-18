import Foundation

struct JSRuntime: Equatable, Sendable {
    let name: String
    let path: URL
}

/// Runs the yt-dlp binary.
struct YtDlpDownloader: Downloader {
    let executable: URL
    let ffmpeg: URL?
    var jsRuntime: JSRuntime?

    func download(url: URL, options: DownloadOptions, into folder: URL,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        let partials = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: partials, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: partials) }
        var source = YtDlpCommand.Source.link(url)
        var choice: FormatChoice?

        if options.format != .audio {
            let file = partials.appendingPathComponent("video.info.json")
            try Data(try await run(YtDlpCommand.probeArguments(url: url, jsRuntime: jsRuntime)).out.utf8).write(to: file)
            if let formats = try? JSONDecoder().decode(VideoInfo.self, from: Data(contentsOf: file)).formats, !formats.isEmpty {
                source = .infoJSON(file)
                choice = FormatPicker.choose(from: formats, options: options, hasFFmpeg: ffmpeg != nil)
                if let choice { onEvent(.chosen(choice)) }
            }
        }

        let arguments = YtDlpCommand.arguments(source: source, options: options, choice: choice, folder: folder,
                                               partialsFolder: partials, hasFFmpeg: ffmpeg != nil,
                                               ffmpegDirectory: ffmpeg?.deletingLastPathComponent(),
                                               jsRuntime: jsRuntime)
        let lines = OutputLines { line in
            if case .event(let event) = YtDlpCommand.parse(line) { onEvent(event) }
        }
        let result = try await run(arguments) { lines.feed($0) }
        guard let saved = Self.savedFile(in: result.out) else { throw DownloadError.failed("yt-dlp finished but did not report a file.") }
        return URL(fileURLWithPath: saved)
    }

    static func savedFile(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            if case .file(let path) = YtDlpCommand.parse(String(line)) { path } else { nil }
        }.last
    }

    private func run(_ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Shell.Result {
        let result = try await Shell.run(executable.path, arguments, timeout: .untilCancelled, onOutput: onOutput)
        guard result.succeeded else { throw DownloadError.failed(YtDlpCommand.friendlyError(from: result.err)) }
        return result
    }
}

/// Program output arrives in arbitrary pieces; this hands on each line once it is complete.
final class OutputLines: @unchecked Sendable {
    private let lock = NSLock()
    private var unfinished = ""
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        var lines = (unfinished + text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        unfinished = String(lines.removeLast())
        lines.filter { !$0.isEmpty }.forEach { onLine(String($0)) }
    }
}

enum YtDlpLocator {
    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/bin/yt-dlp")
    }

    /// Order: $TOOLBOX_YTDLP (debug builds only), then whichever of the bundled and the downloaded copy is newer
    /// (the bundled one goes stale, so "Update yt-dlp" saves a fresh copy that must win), then Homebrew.
    static func findYtDlp() -> URL? {
        #if DEBUG
        if let override = firstExecutable([ProcessInfo.processInfo.environment["TOOLBOX_YTDLP"]]) { return override }
        #endif
        let own = [Bundle.main.url(forResource: "yt-dlp", withExtension: nil)?.path, installedURL.path]
            .compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0) }
            .max { modified($0) < modified($1) }
        return firstExecutable([own, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"])
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    static func makeDownloader() -> YtDlpDownloader? {
        findYtDlp().map { YtDlpDownloader(executable: $0, ffmpeg: MediaTools.ffmpeg(), jsRuntime: findJSRuntime()) }
    }

    static func findJSRuntime(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> JSRuntime? {
        let candidates: [(String, String)] = [
            ("deno", "/opt/homebrew/bin/deno"), ("deno", "/usr/local/bin/deno"), ("deno", home.appendingPathComponent(".deno/bin/deno").path),
            ("node", "/opt/homebrew/bin/node"), ("node", "/usr/local/bin/node"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.1) }
            .map { JSRuntime(name: $0.0, path: URL(fileURLWithPath: $0.1)) }
    }

    private static func firstExecutable(_ paths: [String?]) -> URL? {
        paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
