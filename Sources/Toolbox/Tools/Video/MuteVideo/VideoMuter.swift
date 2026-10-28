import AVFoundation

enum MuteError: LocalizedError {
    case noVideo

    var errorDescription: String? { "This file has no video that can be read." }
}

struct MuteResult: Equatable {
    let url: URL
    /// False when the picture was copied as is.
    let reencoded: Bool
    let originalBytes: Int64
    let newBytes: Int64
    let duration: Double

    /// Bytes the soundtrack took up; zero if the new file turned out no smaller.
    var savedBytes: Int64 { max(originalBytes - newBytes, 0) }
}

enum MuteOutcome: Equatable {
    case muted(MuteResult)
    /// The video had no audio track, so nothing was written.
    case alreadySilent
}

/// Saves a copy of a video without its soundtrack. The original is never touched.
enum VideoMuter {
    /// "Clip (Muted)"; the folder is new for each batch, so a clash only happens for two files of the same name.
    static func outputBase(for source: URL) -> String {
        source.deletingPathExtension().lastPathComponent + " (Muted)"
    }

    /// Copies the picture without re-encoding; if the format does not allow it, re-encodes at the highest quality.
    static func mute(source: URL, into folder: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MuteOutcome {
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw MuteError.noVideo }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { return .alreadySilent }

        let silent = try await pictureOnly(videoTracks)
        let metadata = (try? await asset.load(.metadata)) ?? []
        let (type, ext) = VideoTrimmer.outputType(forExtension: source.pathExtension)
        let output = BatchFiles.uniqueURL(in: folder, name: outputBase(for: source), ext: ext)

        var reencoded = false
        do {
            try await AssetExporter.export(silent, preset: AVAssetExportPresetPassthrough, type: type, metadata: metadata, to: output, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? FileManager.default.removeItem(at: output)
            try await AssetExporter.export(silent, preset: AVAssetExportPresetHighestQuality, type: type, metadata: metadata, to: output, progress: progress)
            reencoded = true
        }
        return .muted(MuteResult(url: output, reencoded: reencoded, originalBytes: size(of: source), newBytes: size(of: output),
                                 duration: (try? await asset.load(.duration).seconds) ?? 0))
    }

    /// A composition holding only the video tracks, turned the way the originals were.
    private static func pictureOnly(_ tracks: [AVAssetTrack]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in tracks {
            let range = try await track.load(.timeRange)
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        return composition
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
