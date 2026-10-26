import Foundation

enum DownloadFormat: String, CaseIterable, Identifiable {
    case best = "Best Quality"
    case p1080 = "1080p"
    case p720 = "720p"
    case audio = "Audio Only (M4A)"

    var id: String { rawValue }

    /// Tallest frame height to accept, or nil for no cap.
    var maxHeight: Int? {
        switch self {
        case .best, .audio: nil
        case .p1080: 1080
        case .p720: 720
        }
    }
}

struct DownloadOptions: Equatable {
    var format: DownloadFormat = .best
    var preferH264 = true
}

enum DownloadEvent: Equatable {
    case title(String)
    /// `fraction` is nil when the size is unknown.
    case progress(fraction: Double?, bytesPerSecond: Double?, etaSeconds: Int?)
}

enum DownloadError: LocalizedError, Equatable {
    case toolMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing: "yt-dlp is not installed."
        case .failed(let message): message
        }
    }
}

/// Anything that can save one link into a folder. `YtDlpDownloader` is the real one.
protocol Downloader: Sendable {
    /// Returns the saved file. Throws `CancellationError` if the task is cancelled.
    func download(url: URL, options: DownloadOptions, into folder: URL,
                  onEvent: @escaping @Sendable (DownloadEvent) -> Void) async throws -> URL
}
