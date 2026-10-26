import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum GifError: LocalizedError {
    case noVideo
    case emptyRange
    case tooLong(Int)
    case frameFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .emptyRange: "The start time is past the end of the video."
        case .tooLong(let max): "Too long for a GIF (more than \(max) frames). Lower the frame rate or convert only part of it."
        case .frameFailed: "A frame of the video could not be read."
        case .writeFailed: "The GIF could not be saved."
        }
    }
}

/// Turns a video into an animated GIF. The original is never touched.
enum GifConverter {
    static func convert(source: URL, settings: GifSettings, into folder: URL,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw GifError.noVideo }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, let range = GifPlan.range(duration: duration, part: settings.part) else { throw GifError.emptyRange }
        let natural = try await track.load(.naturalSize).applying(try await track.load(.preferredTransform))

        let times = GifPlan.frameTimes(start: range.start, length: range.length, fps: settings.fps)
        guard times.count <= GifPlan.maxFrames else { throw GifError.tooLong(GifPlan.maxFrames) }
        let delays = GifPlan.delays(count: times.count, fps: settings.fps)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = GifPlan.outputSize(source: natural, maxWidth: settings.maxWidth)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil)
        else { throw GifError.writeFailed }
        // Loop count 0 repeats forever; leaving the key out makes the GIF play once.
        let fileProperties: [CFString: Any] = settings.loopForever ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] : [:]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)

        do {
            var written = 0
            let cmTimes = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
            for await result in generator.images(for: cmTimes) {
                try Task.checkCancellation()
                guard case .success(_, let image, _) = result else { throw GifError.frameFailed }
                let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[written]]]
                CGImageDestinationAddImage(destination, image, frame as CFDictionary)
                written += 1
                progress(Double(written) / Double(times.count))
            }
            try Task.checkCancellation()
            guard written == times.count, CGImageDestinationFinalize(destination) else { throw GifError.writeFailed }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
