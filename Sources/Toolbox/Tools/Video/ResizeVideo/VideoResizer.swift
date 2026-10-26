import AVFoundation

enum ResizeError: LocalizedError {
    case noVideo
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .exportFailed: "The video could not be resized."
        }
    }
}

/// Re-renders a video at a new size into a new file. The original is never touched.
enum VideoResizer {
    static func resize(source: URL, settings: ResizeSettings, into folder: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ResizeError.noVideo }
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)

        let layout = ResizePlan.layout(source: natural.applying(transform), settings: settings)
        let placement = transform
            .concatenating(CGAffineTransform(scaleX: layout.scaleX, y: layout.scaleY))
            .concatenating(CGAffineTransform(translationX: layout.offset.x, y: layout.offset.y))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(placement, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = layout.renderSize
        composition.frameDuration = CMTime(value: 1, timescale: fps > 1 ? CMTimeScale(fps.rounded()) : 30)
        composition.instructions = [instruction]

        let preset = settings.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let made = AVAssetExportSession(asset: asset, presetName: preset), made.supportedFileTypes.contains(.mp4)
        else { throw ResizeError.exportFailed }
        let session = Session(made)
        let name = source.deletingPathExtension().lastPathComponent + " (\(Int(layout.renderSize.width))x\(Int(layout.renderSize.height)))"
        let output = BatchFiles.uniqueURL(in: folder, name: name, ext: "mp4")
        session.value.outputURL = output
        session.value.outputFileType = .mp4
        session.value.videoComposition = composition

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
                try? FileManager.default.removeItem(at: output)
                throw CancellationError()
            default:
                try? FileManager.default.removeItem(at: output)
                throw session.value.error ?? ResizeError.exportFailed
            }
        } onCancel: {
            session.value.cancelExport()
        }
        return output
    }

    private final class Session: @unchecked Sendable {
        let value: AVAssetExportSession
        init(_ value: AVAssetExportSession) { self.value = value }
    }
}
