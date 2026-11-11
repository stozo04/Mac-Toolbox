import Foundation

/// Pure helpers that build the yt-dlp command line and read its output, so both are testable.
enum YtDlpCommand {
    static let progressPrefix = "TBX_PROGRESS|"
    static let titlePrefix = "TBX_TITLE|"
    static let filePrefix = "TBX_FILE|"

    enum Source: Equatable {
        case link(URL)
        case infoJSON(URL)
    }

    static func probeArguments(url: URL, jsRuntime: JSRuntime?) -> [String] {
        ["-J", "--no-playlist", "--no-warnings"] + runtimeArguments(jsRuntime) + [url.absoluteString]
    }

    static func arguments(source: Source, options: DownloadOptions, choice: FormatChoice?, folder: URL,
                          hasFFmpeg: Bool, ffmpegDirectory: URL?, jsRuntime: JSRuntime?) -> [String] {
        var a = [
            "--no-playlist", "--newline", "--progress", "--no-warnings",
            "-P", folder.path,
            "-o", "%(title).150B [%(id)s].%(ext)s",
            "--progress-template",
            "download:\(progressPrefix)%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--print", "pre_process:\(titlePrefix)%(title)s",
            "--print", "after_move:\(filePrefix)%(filepath)s",
        ]
        a += runtimeArguments(jsRuntime)
        if let ffmpegDirectory { a += ["--ffmpeg-location", ffmpegDirectory.path] }
        a += formatArguments(options: options, choice: choice, hasFFmpeg: hasFFmpeg)
        switch source {
        case .link(let url): a.append(url.absoluteString)
        case .infoJSON(let file): a += ["--load-info-json", file.path]
        }
        return a
    }

    private static func runtimeArguments(_ runtime: JSRuntime?) -> [String] {
        runtime.map { ["--js-runtimes", "\($0.name):\($0.path.path)"] } ?? []
    }

    private static func formatArguments(options: DownloadOptions, choice: FormatChoice?, hasFFmpeg: Bool) -> [String] {
        if options.format == .audio {
            return ["-f", "ba[ext=m4a]/ba/b"] + (hasFFmpeg ? ["-x", "--audio-format", "m4a"] : [])
        }
        if let choice {
            return ["-f", choice.formatSpec] + (hasFFmpeg ? ["--merge-output-format", "mp4"] : [])
        }
        if hasFFmpeg {
            var sort: [String] = []
            if options.mostCompatible { sort.append("vcodec:h264") }
            sort.append(options.format.maxHeight.map { "res:\($0)" } ?? "res")
            sort.append("fps")
            if options.mostCompatible { sort.append("acodec:aac") }
            return ["-f", "bv*+ba/b", "-S", sort.joined(separator: ","), "--merge-output-format", "mp4"]
        }
        let cap = options.format.maxHeight.map { "[height<=\($0)]" } ?? ""
        return ["-f", "b\(cap)[ext=mp4]/b\(cap)/b"]
    }

    enum Line: Equatable {
        case event(DownloadEvent)
        case file(String)
        case other
    }

    static func parse(_ line: String) -> Line {
        if line.hasPrefix(progressPrefix) {
            let f = line.dropFirst(progressPrefix.count).split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 5 else { return .other }
            let downloaded = Double(f[0])
            let total = Double(f[1]) ?? Double(f[2])
            var fraction: Double?
            if let downloaded, let total, total > 0 { fraction = min(downloaded / total, 1) }
            let speed = Double(f[3])
            let eta = Double(f[4]).map { Int($0) }
            return .event(.progress(fraction: fraction, bytesPerSecond: speed, etaSeconds: eta))
        }
        if line.hasPrefix(titlePrefix) { return .event(.title(String(line.dropFirst(titlePrefix.count)))) }
        if line.hasPrefix(filePrefix) { return .file(String(line.dropFirst(filePrefix.count))) }
        return .other
    }

    /// Turns yt-dlp's stderr into a short sentence for the UI.
    static func friendlyError(from stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        var message = lines.last(where: { $0.hasPrefix("ERROR:") }) ?? lines.last ?? "The download failed."
        message = message.replacingOccurrences(of: "ERROR: ", with: "")
        // Drop the "[youtube] abc123:" extractor prefix.
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            var rest = message[message.index(after: close)...].drop(while: { $0 == " " })
            if let colon = rest.firstIndex(of: ":"), rest[..<colon].split(separator: " ").count <= 1 {
                rest = rest[rest.index(after: colon)...].drop(while: { $0 == " " })
            }
            message = String(rest)
        }
        return message.isEmpty ? "The download failed." : message
    }
}
