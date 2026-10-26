import CoreGraphics
import Foundation

struct GifSettings: Equatable {
    static let frameRates = [10, 15, 24]
    /// Width choices in pixels; nil keeps the original width.
    static let widths: [Int?] = [320, 480, 640, nil]

    var fps = 15
    var maxWidth: Int? = 480
    var loopForever = true
    /// Start and length in seconds when only part of each video is converted.
    var part: (start: Double, length: Double)?

    static func == (a: GifSettings, b: GifSettings) -> Bool {
        a.fps == b.fps && a.maxWidth == b.maxWidth && a.loopForever == b.loopForever
            && a.part?.start == b.part?.start && a.part?.length == b.part?.length
    }
}

/// The pure arithmetic behind a conversion: which frames to take, how long each shows, how big the GIF is.
enum GifPlan {
    /// More frames than this would need gigabytes of memory to write.
    static let maxFrames = 3000

    /// The range to convert, clamped to the video. Nil when nothing of the video is left.
    static func range(duration: Double, part: (start: Double, length: Double)?) -> (start: Double, length: Double)? {
        guard let part else { return duration > 0 ? (0, duration) : nil }
        guard part.start < duration, part.length > 0 else { return nil }
        return (part.start, min(part.length, duration - part.start))
    }

    static func frameTimes(start: Double, length: Double, fps: Int) -> [Double] {
        let count = max(1, Int((length * Double(fps)).rounded(.down)))
        return (0..<count).map { start + Double($0) / Double(fps) }
    }

    /// GIF delays are whole hundredths of a second. Rounding the running total instead of each frame keeps the
    /// average speed exact (15 fps becomes 7,7,6 hundredths rather than 7 every time).
    static func delays(count: Int, fps: Int) -> [Double] {
        let edge = { (i: Int) in (Double(i) / Double(fps) * 100).rounded() }
        return (0..<count).map { (edge($0 + 1) - edge($0)) / 100 }
    }

    /// Fits the video to the width without ever enlarging it.
    static func outputSize(source: CGSize, maxWidth: Int?) -> CGSize {
        let w = abs(source.width), h = abs(source.height)
        guard let maxWidth, w > CGFloat(maxWidth) else { return CGSize(width: w.rounded(), height: h.rounded()) }
        return CGSize(width: CGFloat(maxWidth), height: max(1, (h * CGFloat(maxWidth) / w).rounded()))
    }
}
