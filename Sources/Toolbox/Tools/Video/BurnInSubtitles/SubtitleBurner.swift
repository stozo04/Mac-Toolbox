import AVFoundation
import QuartzCore

enum BurnError: LocalizedError {
    case noVideo
    case nothingToShow

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .nothingToShow: "None of the captions fall within this video."
        }
    }
}

struct BurnResult: Equatable {
    let url: URL
    let bytes: Int64
    let cueCount: Int
}

/// Draws captions into a copy of a video. The original is never touched.
enum SubtitleBurner {
    /// The captions that show within `duration`, the last one cut off at the end of the video.
    static func visible(_ cues: [SubtitleCue], duration: Double) -> [SubtitleCue] {
        cues.filter { $0.start < duration }.map { SubtitleCue(start: $0.start, end: min($0.end, duration), text: $0.text) }
    }

    static func burn(source: URL, cues: [SubtitleCue], style: CaptionStyle, into folder: URL,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> BurnResult {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw BurnError.noVideo }
        let duration = try await asset.load(.duration)
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let metadata = (try? await asset.load(.metadata)) ?? []
        let shown = visible(cues, duration: duration.seconds)
        guard !shown.isEmpty else { throw BurnError.nothingToShow }

        // The picture as it is shown (turned upright), with its corner at the origin.
        let turned = CGRect(origin: .zero, size: natural).applying(transform)
        let renderSize = CGSize(width: (turned.width / 2).rounded() * 2, height: (turned.height / 2).rounded() * 2)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -turned.minX, y: -turned.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]

        let videoLayer = CALayer(), parent = CALayer()
        for l in [videoLayer, parent] { l.frame = CGRect(origin: .zero, size: renderSize) }
        parent.addSublayer(videoLayer)
        for cue in shown {
            guard let caption = CaptionRenderer.render(cue.text, style: style, videoSize: renderSize) else { continue }
            parent.addSublayer(captionLayer(caption, start: cue.start, end: cue.end, total: duration.seconds))
        }

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: fps > 1 ? CMTimeScale(fps.rounded()) : 30)
        composition.instructions = [instruction]
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        let (type, ext) = VideoTrimmer.outputType(forExtension: source.pathExtension)
        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent + " (Subtitled)", ext: ext)
        try await AssetExporter.export(asset, preset: AVAssetExportPresetHighestQuality, type: type, metadata: metadata,
                                       videoComposition: composition, to: output, progress: progress)
        let bytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return BurnResult(url: output, bytes: bytes, cueCount: shown.count)
    }

    /// A layer that is invisible except between `start` and `end` seconds of the video.
    private static func captionLayer(_ caption: RenderedCaption, start: Double, end: Double, total: Double) -> CALayer {
        let layer = CALayer()
        layer.contents = caption.image
        layer.frame = caption.frame
        layer.opacity = 0
        let from = start / total, to = end / total
        // Discrete animation needs one more key time than values, ending at 1: value i holds from keyTimes[i] to keyTimes[i + 1].
        let (values, keyTimes): ([Float], [NSNumber]) =
            from <= 0 && to >= 1 ? ([1], [0, 1])
            : from <= 0 ? ([1, 0], [0, NSNumber(value: to), 1])
            : to >= 1 ? ([0, 1], [0, NSNumber(value: from), 1])
            : ([0, 1, 0], [0, NSNumber(value: from), NSNumber(value: to), 1])
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "visible")
        return layer
    }
}
