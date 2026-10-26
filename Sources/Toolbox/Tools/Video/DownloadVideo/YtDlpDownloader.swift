import Foundation

/// Finds, installs and runs the yt-dlp binary.
struct YtDlpDownloader: Downloader {
    let executable: URL
    let ffmpeg: URL?

    func download(url: URL, options: DownloadOptions, into folder: URL,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        let process = Process()
        process.executableURL = executable
        process.arguments = YtDlpCommand.arguments(url: url, options: options, folder: folder,
                                                   hasFFmpeg: ffmpeg != nil,
                                                   ffmpegDirectory: ffmpeg?.deletingLastPathComponent())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try process.run()
            let errors = Task { try await Self.text(of: err) }
            var saved: String?
            for try await line in out.fileHandleForReading.bytes.lines {
                switch YtDlpCommand.parse(line) {
                case .event(let e): onEvent(e)
                case .file(let path): saved = path
                case .other: break
                }
            }
            let stderr = (try? await errors.value) ?? ""
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw DownloadError.failed(YtDlpCommand.friendlyError(from: stderr))
            }
            guard let saved else { throw DownloadError.failed("yt-dlp finished but did not report a file.") }
            return URL(fileURLWithPath: saved)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func text(of pipe: Pipe) async throws -> String {
        var s = ""
        for try await line in pipe.fileHandleForReading.bytes.lines { s += line + "\n" }
        return s
    }
}

enum YtDlpLocator {
    static let releaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    static var installedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Toolbox/bin/yt-dlp")
    }

    /// Order: $TOOLBOX_YTDLP, then whichever of the bundled and the downloaded copy is newer
    /// (the bundled one goes stale, so "Update yt-dlp" saves a fresh copy that must win), then Homebrew.
    static func findYtDlp() -> URL? {
        if let override = firstExecutable([ProcessInfo.processInfo.environment["TOOLBOX_YTDLP"]]) { return override }
        let own = [Bundle.main.url(forResource: "yt-dlp", withExtension: nil)?.path, installedURL.path]
            .compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0) }
            .max { modified($0) < modified($1) }
        return firstExecutable([own, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"])
    }

    private static func modified(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// yt-dlp also needs `ffprobe` next to this file (it is bundled alongside).
    static func findFFmpeg() -> URL? {
        firstExecutable([
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil)?.path,
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
        ])
    }

    static func makeDownloader() -> YtDlpDownloader? {
        findYtDlp().map { YtDlpDownloader(executable: $0, ffmpeg: findFFmpeg()) }
    }

    /// Downloads the official standalone yt-dlp build into Application Support.
    static func install() async throws {
        let (tmp, response) = try await URLSession.shared.download(from: releaseURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.failed("Could not download yt-dlp from GitHub.")
        }
        let fm = FileManager.default
        let dest = installedURL
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    private static func firstExecutable(_ paths: [String?]) -> URL? {
        paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
