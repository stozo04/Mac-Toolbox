import AVFoundation

enum TrimError: LocalizedError {
    case noVideo
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .exportFailed: "The clip could not be saved."
        }
    }
}

struct TrimResult {
    let url: URL
    /// False when the video was copied as is.
    let reencoded: Bool
}

/// Cuts a time range out of a video into a new file. The original is never touched.
enum VideoTrimmer {
    /// Containers a trimmed copy can keep; anything else is written as MOV.
    static func outputType(forExtension ext: String) -> (type: AVFileType, ext: String) {
        switch ext.lowercased() {
        case "mp4": (.mp4, "mp4")
        case "m4v": (.m4v, "m4v")
        default: (.mov, "mov")
        }
    }

    static func outputName(for source: URL, ext: String) -> String {
        source.deletingPathExtension().lastPathComponent + " (Trimmed)." + ext
    }

    /// Copies the streams without re-encoding; if the format does not allow it, re-encodes at the highest quality.
    static func trim(source: URL, start: Double, end: Double, into folder: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> TrimResult {
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw TrimError.noVideo }
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let (type, ext) = outputType(forExtension: source.pathExtension)
        let output = folder.appendingPathComponent(outputName(for: source, ext: ext))

        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, type: type, range: range, to: output, progress: progress)
            return TrimResult(url: output, reencoded: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            try await export(asset, preset: AVAssetExportPresetHighestQuality, type: type, range: range, to: output, progress: progress)
            return TrimResult(url: output, reencoded: true)
        }
    }

    private final class Session: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }

    private static func export(_ asset: AVAsset, preset: String, type: AVFileType, range: CMTimeRange, to url: URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let made = AVAssetExportSession(asset: asset, presetName: preset),
              made.supportedFileTypes.contains(type) else { throw TrimError.exportFailed }
        let session = Session(made)
        session.value.outputURL = url
        session.value.outputFileType = type
        session.value.timeRange = range

        try await withTaskCancellationHandler {
            let poll = Task {
                while !Task.isCancelled {
                    progress(Double(session.value.progress))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.value.exportAsynchronously { done.resume() }
            }
            poll.cancel()
            switch session.value.status {
            case .completed: progress(1)
            case .cancelled:
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            default:
                try? FileManager.default.removeItem(at: url)
                throw session.value.error ?? TrimError.exportFailed
            }
        } onCancel: {
            session.value.cancelExport()
        }
    }
}
