import AVFoundation
import CoreGraphics
import ImageIO

struct VaultLook: Hashable, Sendable {
    typealias FrameHash = [UInt64]

    let frames: [FrameHash]
    let seconds: [Double]
    let aspect: Double

    static let maxFrameDistance = 40
    static let maxSingleFrameDistance = 24
    static let maxAspectDifference = 0.06
    private static let flatBits = 24

    init(frames: [FrameHash], seconds: [Double] = [], aspect: Double) {
        self.frames = frames
        self.seconds = seconds
        self.aspect = aspect
    }

    var isVideo: Bool { !seconds.isEmpty }

    func resembles(_ other: VaultLook) -> Bool {
        guard isVideo == other.isVideo,
              abs(aspect - other.aspect) <= Self.maxAspectDifference * max(aspect, other.aspect) else { return false }
        let pairs = isVideo ? framesAtSameTimes(as: other) : Array(zip(frames, other.frames))
        guard !pairs.isEmpty, pairs.contains(where: { Self.hasDetail($0.0) && Self.hasDetail($0.1) }) else { return false }
        let limit = pairs.count == 1 ? Self.maxSingleFrameDistance : Self.maxFrameDistance
        return pairs.allSatisfy { Self.distance($0.0, $0.1) <= limit }
    }

    private func framesAtSameTimes(as other: VaultLook) -> [(FrameHash, FrameHash)] {
        let theirs = Dictionary(zip(other.seconds, other.frames), uniquingKeysWith: { first, _ in first })
        return zip(seconds, frames).compactMap { second, frame in theirs[second].map { (frame, $0) } }
    }

    static func distance(_ a: FrameHash, _ b: FrameHash) -> Int {
        zip(a, b).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    private static func hasDetail(_ hash: FrameHash) -> Bool {
        let set = hash.reduce(0) { $0 + $1.nonzeroBitCount }
        return set >= flatBits && set <= hash.count * 64 - flatBits
    }
}

enum VaultLookReader {
    static let videoSeconds: [Double] = [0.25, 1, 2.5, 4, 6, 8]
    private static let endMargin = 0.05
    private static let hashSide = 16
    private static let samplePixels = 256
    private static let parallelLoads = 6

    static func looks(of items: [VaultItem], durations: [VaultItem: Double]) async -> [VaultItem: VaultLook] {
        await withTaskGroup(of: (VaultItem, VaultLook?).self) { group in
            var found: [VaultItem: VaultLook] = [:]
            var pending = items.makeIterator()
            for _ in 0..<parallelLoads {
                guard let item = pending.next() else { break }
                group.addTask { (item, await look(of: item, duration: durations[item])) }
            }
            for await (item, result) in group {
                if let result { found[item] = result }
                if !Task.isCancelled, let next = pending.next() {
                    group.addTask { (next, await look(of: next, duration: durations[next])) }
                }
            }
            return found
        }
    }

    static func look(of item: VaultItem, duration: Double?) async -> VaultLook? {
        switch item.kind {
        case .image:
            guard let image = imageThumbnail(item.url) else { return nil }
            return VaultLook(frames: [hash(image)], aspect: aspect(of: image))
        case .video:
            return await videoLook(item.url, duration: duration)
        }
    }

    static func sampleSeconds(forDuration duration: Double) -> [Double] {
        videoSeconds.filter { $0 < duration - endMargin }
    }

    static func hash(_ image: CGImage) -> VaultLook.FrameHash {
        let width = hashSide + 1, height = hashSide
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var words = [UInt64](repeating: 0, count: hashSide * hashSide / 64)
        for row in 0..<height {
            for column in 0..<hashSide where pixels[row * width + column] > pixels[row * width + column + 1] {
                let bit = row * hashSide + column
                words[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        return words
    }

    private static func videoLook(_ url: URL, duration: Double?) async -> VaultLook? {
        let asset = AVURLAsset(url: url)
        var seconds = duration
        if seconds == nil { seconds = try? await asset.load(.duration).seconds }
        guard let duration = seconds, duration.isFinite, duration > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: samplePixels, height: samplePixels)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = sampleSeconds(forDuration: duration)
        var frames: [VaultLook.FrameHash] = []
        var shape: Double?
        for second in times {
            guard let image = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image else { return nil }
            frames.append(hash(image))
            shape = shape ?? aspect(of: image)
        }
        guard let shape else { return nil }
        return VaultLook(frames: frames, seconds: times, aspect: shape)
    }

    private static func imageThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: samplePixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func aspect(of image: CGImage) -> Double {
        image.height > 0 ? Double(image.width) / Double(image.height) : 1
    }
}
