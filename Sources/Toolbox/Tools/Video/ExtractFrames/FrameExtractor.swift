import AVFoundation
import ImageIO

enum FrameError: LocalizedError {
    case noVideo
    case emptyRange
    case tooMany(Int)
    case frameFailed(Double)
    case writeFailed(String)
    case zipFailed(String)
    case folderNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: "This file has no video that can be read."
        case .emptyRange: "The start time is past the end of the video."
        case .tooMany(let max): "That would be more than \(max) frames. Pick a longer gap, fewer frames per second or a shorter part."
        case .frameFailed(let t): "The frame at \(TrimTime.format(t)) could not be read."
        case .writeFailed(let name): "\(name) could not be saved."
        case .zipFailed(let reason): "The ZIP could not be made. \(reason)"
        case .folderNotWritable(let name): "\(name) can't be written to. Choose another folder under Save to."
        }
    }
}

/// What one run produced.
struct FrameResult {
    /// The folder of images, or nil for "ZIP only".
    var folder: URL?
    var frames: [URL]
    var zip: URL?
    var count: Int
}

/// Saves stills from a video. The original is never touched.
enum FrameExtractor {
    /// How long the picture lasts. The video track's end, not the file's: sound can run on past the last frame.
    /// Where the picture starts in the file and how long it lasts; nil when there is none.
    static func videoSpan(of url: URL) async -> (start: Double, length: Double)? {
        try? await videoSpan(AVURLAsset(url: url))
    }

    /// Where the picture starts in the file and how long it lasts. Times in the plan count from that start.
    private static func videoSpan(_ asset: AVAsset) async throws -> (start: Double, length: Double)? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let range = try await track.load(.timeRange)
        let start = range.start.seconds, length = range.duration.seconds
        guard start.isFinite, length.isFinite, length > 0 else { return nil }
        return (max(0, start), length)
    }

    /// Grabs every frame the settings ask for. `destination` is the folder that holds the output
    /// (the video's own folder in the app), `progress` gets 0...1 and each saved frame.
    static func extract(source: URL, settings: FrameSettings, destination: URL,
                        progress: @escaping @Sendable (Double, URL?) -> Void) async throws -> FrameResult {
        let asset = AVURLAsset(url: source)
        guard let video = try await videoSpan(asset) else { throw FrameError.noVideo }
        let times = FramePlan.times(duration: video.length, settings: settings)
        guard !times.isEmpty else { throw FrameError.emptyRange }
        guard times.count <= FramePlan.maxFrames else { throw FrameError.tooMany(FramePlan.maxFrames) }

        let base = source.deletingPathExtension().lastPathComponent
        let zipOnly = settings.output == .zipOnly
        let fm = FileManager.default
        // "ZIP only" still needs the images on disk for a moment; they go to a temporary folder.
        let folder = zipOnly
            ? fm.temporaryDirectory.appendingPathComponent("Toolbox Frames \(UUID().uuidString)").appendingPathComponent("\(base) Frames")
            : uniqueFolder(in: destination, name: "\(base) Frames")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { if zipOnly { try? fm.removeItem(at: folder.deletingLastPathComponent()) } }

        var frames: [URL] = []
        do {
            let generator = makeGenerator(asset, settings: settings)
            let cmTimes = times.map { CMTime(seconds: video.start + $0, preferredTimescale: 600) }
            for await result in generator.images(for: cmTimes) {
                try Task.checkCancellation()
                let index = frames.count
                guard case .success(_, let image, _) = result else { throw FrameError.frameFailed(times[index]) }
                let url = folder.appendingPathComponent(FramePlan.fileName(base: base, index: index + 1, time: times[index], format: settings.format))
                try write(image, to: url, settings: settings)
                frames.append(url)
                progress(Double(frames.count) / Double(times.count) * (settings.output == .images ? 1 : 0.95), zipOnly ? nil : url)
            }
            try Task.checkCancellation()
            guard frames.count == times.count else { throw FrameError.frameFailed(times[frames.count]) }

            var zip: URL?
            if settings.output != .images {
                let zipFile = uniqueFile(in: destination, name: "\(base) Frames", ext: "zip")
                try await makeZip(of: folder, at: zipFile)
                zip = zipFile
                progress(1, nil)
            }
            return FrameResult(folder: zipOnly ? nil : folder, frames: zipOnly ? [] : frames, zip: zip, count: frames.count)
        } catch {
            // A half-finished run leaves nothing behind.
            if !zipOnly { try? fm.removeItem(at: folder) }
            throw error
        }
    }

    /// Saves the single frame at `time` (Pick by hand) into `folder`, numbered after the frames already there.
    /// `time` is the player's time in the file; the file name counts from where the picture starts, like a batch run.
    static func extractOne(source: URL, at time: Double, settings: FrameSettings, folder: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let video = try await videoSpan(asset) else { throw FrameError.noVideo }
        let generator = makeGenerator(asset, settings: settings)
        let at = CMTime(seconds: max(time, video.start), preferredTimescale: 600)
        let nameTime = max(0, time - video.start)
        let image: CGImage
        if let exact = try? await generator.image(at: at).image {
            image = exact
        } else {
            // The very end of a video (the scrubber dragged all the way right) is after its last frame:
            // take the nearest frame before it instead.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            do { image = try await generator.image(at: at).image } catch { throw FrameError.frameFailed(time) }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = source.deletingPathExtension().lastPathComponent
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasPrefix(base + "_") }.count ?? 0
        var index = existing + 1
        var url = folder.appendingPathComponent(FramePlan.fileName(base: base, index: index, time: nameTime, format: settings.format))
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = folder.appendingPathComponent(FramePlan.fileName(base: base, index: index, time: nameTime, format: settings.format))
        }
        try write(image, to: url, settings: settings)
        return url
    }

    // MARK: Pieces

    private static func makeGenerator(_ asset: AVAsset, settings: FrameSettings) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // A square box limits the longest side; the generator keeps the aspect ratio and never enlarges.
        if let side = settings.maxSide { generator.maximumSize = CGSize(width: side, height: side) }
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    static func write(_ image: CGImage, to url: URL, settings: FrameSettings) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, settings.format.type.identifier as CFString, 1, nil)
        else { throw FrameError.writeFailed(url.lastPathComponent) }
        let props: [CFString: Any] = settings.format.isLossy ? [kCGImageDestinationLossyCompressionQuality: settings.quality] : [:]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw FrameError.writeFailed(url.lastPathComponent)
        }
    }

    /// `ditto` makes a ZIP with the folder inside it, without the hidden __MACOSX files other systems show as clutter.
    static func makeZip(of folder: URL, at zip: URL) async throws {
        let result = try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", folder.path, zip.path])
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: zip)
            // Cancel stops ditto, which then exits with an error; that is a cancellation, not a failure.
            try Task.checkCancellation()
            throw FrameError.zipFailed(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// "Clip Frames", or "Clip Frames 2" when that folder already exists.
    static func uniqueFolder(in parent: URL, name: String) -> URL {
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(name) \(n)", isDirectory: true)
            n += 1
        }
        return url
    }

    static func uniqueFile(in parent: URL, name: String, ext: String) -> URL { BatchFiles.uniqueURL(in: parent, name: name, ext: ext) }
}
