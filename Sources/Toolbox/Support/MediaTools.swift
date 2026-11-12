import Foundation

/// ffmpeg and ffprobe: bundled inside Toolbox.app, or Homebrew's for development runs.
struct MediaTools: Equatable, Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    static func find() -> MediaTools? {
        guard let ffmpeg = ffmpeg(), let ffprobe = executable("ffprobe") else { return nil }
        return MediaTools(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    static func ffmpeg() -> URL? { executable("ffmpeg") }

    private static func executable(_ name: String) -> URL? {
        [Bundle.main.url(forResource: name, withExtension: nil)?.path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
            .compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}
