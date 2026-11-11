import Foundation

struct JSRuntime: Equatable, Sendable {
    let name: String
    let path: URL
}

/// Finds, installs and runs the yt-dlp binary.
struct YtDlpDownloader: Downloader {
    let executable: URL
    let ffmpeg: URL?
    var jsRuntime: JSRuntime?

    func download(url: URL, options: DownloadOptions, into folder: URL,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL {
        var source = YtDlpCommand.Source.link(url)
        var choice: FormatChoice?
        var infoFile: URL?
        defer { if let infoFile { try? FileManager.default.removeItem(at: infoFile) } }

        if options.format != .audio {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("toolbox-\(UUID().uuidString).info.json")
            infoFile = file
            try await probe(url, into: file)
            if let formats = try? JSONDecoder().decode(VideoInfo.self, from: Data(contentsOf: file)).formats, !formats.isEmpty {
                source = .infoJSON(file)
                choice = FormatPicker.choose(from: formats, options: options, hasFFmpeg: ffmpeg != nil)
                if let choice { onEvent(.chosen(choice)) }
            }
        }

        var saved: String?
        let arguments = YtDlpCommand.arguments(source: source, options: options, choice: choice, folder: folder,
                                               hasFFmpeg: ffmpeg != nil,
                                               ffmpegDirectory: ffmpeg?.deletingLastPathComponent(),
                                               jsRuntime: jsRuntime)
        try await run(arguments) { line in
            switch YtDlpCommand.parse(line) {
            case .event(let e): onEvent(e)
            case .file(let path): saved = path
            case .other: break
            }
        }
        guard let saved else { throw DownloadError.failed("yt-dlp finished but did not report a file.") }
        return URL(fileURLWithPath: saved)
    }

    private func probe(_ url: URL, into file: URL) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw DownloadError.failed("Could not create a temporary file for the video details.")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try await run(YtDlpCommand.probeArguments(url: url, jsRuntime: jsRuntime), output: .file(handle))
    }

    private enum Output {
        case lines((String) -> Void)
        case file(FileHandle)
    }

    private func run(_ arguments: [String], onLine: @escaping (String) -> Void) async throws {
        try await run(arguments, output: .lines(onLine))
    }

    private func run(_ arguments: [String], output: Output) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        switch output {
        case .lines: process.standardOutput = out
        case .file(let handle): process.standardOutput = handle
        }
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exit = ProcessExit()
        process.terminationHandler = { _ in exit.finish() }

        try await withTaskCancellationHandler {
            try process.run()
            let errors = Task { try await Self.text(of: err) }
            if case .lines(let onLine) = output {
                for try await line in out.fileHandleForReading.bytes.lines { onLine(line) }
            }
            let stderr = (try? await errors.value) ?? ""
            await exit.wait()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw DownloadError.failed(YtDlpCommand.friendlyError(from: stderr))
            }
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

private final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    private var waiter: CheckedContinuation<Void, Never>?

    func finish() {
        lock.lock()
        exited = true
        let resume = waiter
        waiter = nil
        lock.unlock()
        resume?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if exited {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
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
        findYtDlp().map { YtDlpDownloader(executable: $0, ffmpeg: findFFmpeg(), jsRuntime: findJSRuntime()) }
    }

    static func findJSRuntime(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> JSRuntime? {
        let candidates: [(String, String)] = [
            ("deno", "/opt/homebrew/bin/deno"), ("deno", "/usr/local/bin/deno"), ("deno", home.appendingPathComponent(".deno/bin/deno").path),
            ("node", "/opt/homebrew/bin/node"), ("node", "/usr/local/bin/node"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.1) }
            .map { JSRuntime(name: $0.0, path: URL(fileURLWithPath: $0.1)) }
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
