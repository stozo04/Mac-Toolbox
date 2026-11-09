import CoreGraphics
import Foundation

enum VideoCompressQuality: String, CaseIterable, Identifiable {
    case high = "High"
    case balanced = "Balanced"
    case small = "Small"
    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .high: "A barely noticeable difference from the original."
        case .balanced: "A good balance of quality and file size."
        case .small: "The smallest files. Fine detail can look softer."
        }
    }

    /// Bits spent on each pixel of each frame with H.264 (1080p at 30 fps comes to about 7.5, 4.5 and 2.5 Mbit/s).
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.12
        case .balanced: 0.07
        case .small: 0.04
        }
    }

    /// Stereo soundtrack bitrate in bits per second; a mono one gets half.
    var audioBitrate: Int {
        switch self {
        case .high: 160_000
        case .balanced: 128_000
        case .small: 96_000
        }
    }
}

enum VideoCompressCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }

    /// HEVC holds the same quality in roughly half the bits.
    var bitrateFactor: Double { self == .hevc ? 0.55 : 1 }

    var note: String {
        switch self {
        case .h264: "H.264 plays everywhere."
        case .hevc: "HEVC files are about half the size but take longer to encode and may not play on older devices."
        }
    }
}

/// Caps the size of the picture by its shorter side, so "720p" means the same for a vertical phone video.
enum VideoCompressMaxSize: String, CaseIterable, Identifiable {
    case original = "Original"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"
    var id: String { rawValue }

    var shortSide: Int? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
}

struct VideoCompressSettings: Equatable {
    var quality = VideoCompressQuality.balanced
    var codec = VideoCompressCodec.h264
    var maxSize = VideoCompressMaxSize.original
    var removeAudio = false
    var hardwareEncoder = false
}

/// The numbers behind a compression run. Pure arithmetic, so it can be tested without video.
enum VideoCompressPlan {
    /// Video encoders need even dimensions, so odd sizes round down.
    static func even(_ n: CGFloat) -> CGFloat { max(2, (n / 2).rounded(.down) * 2) }

    /// The size of the new picture: shrunk so its shorter side fits `maxShortSide`, never enlarged.
    static func outputSize(source: CGSize, maxShortSide: Int?) -> CGSize {
        let w = max(abs(source.width), 1), h = max(abs(source.height), 1)
        var scale: CGFloat = 1
        if let cap = maxShortSide, min(w, h) > CGFloat(cap) { scale = CGFloat(cap) / min(w, h) }
        return CGSize(width: even(w * scale), height: even(h * scale))
    }

    /// Average video bitrate in bits per second.
    /// `sourceBitrate` is the original's, so a clip that is already small is not given more bits than it had.
    static func videoBitrate(size: CGSize, frameRate: Double, settings: VideoCompressSettings, sourceBitrate: Double?) -> Int {
        // High frame rates need fewer bits per frame, because neighbouring frames are almost the same.
        let fps = frameRate > 1 ? frameRate : 30
        let effectiveFps = fps <= 30 ? fps : 30 + (fps - 30) * 0.5
        var bits = Double(size.width * size.height) * effectiveFps
            * settings.quality.bitsPerPixel * settings.codec.bitrateFactor
        // The hardware encoder is less efficient, so it is given a few more bits to look as good.
        if settings.hardwareEncoder { bits *= 1.2 }
        if let sourceBitrate, sourceBitrate > 0 { bits = min(bits, sourceBitrate * 0.9) }
        return Int(max(bits, 100_000))
    }

    /// AAC settings for the soundtrack: stereo at most, 44.1 or 48 kHz.
    static func audioFormat(channels: Int, sampleRate: Double, quality: VideoCompressQuality) -> (channels: Int, sampleRate: Double, bitrate: Int) {
        let ch = min(max(channels, 1), 2)
        let rate: Double = sampleRate > 0 && sampleRate <= 44_100 ? 44_100 : 48_000
        return (ch, rate, quality.audioBitrate * ch / 2)
    }
}
