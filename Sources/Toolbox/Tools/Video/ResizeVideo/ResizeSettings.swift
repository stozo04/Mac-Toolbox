import CoreGraphics
import Foundation

enum ResizeFit: String, CaseIterable, Identifiable {
    case blackBars = "Add black bars"
    case crop = "Crop to fill"
    case within = "Fit within size"
    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .blackBars: "The video is scaled to fit and black bars fill any empty space."
        case .crop: "The video is scaled to fill the frame and the edges that don't fit are cut off."
        case .within: "The video is scaled to fit inside the size. The picture keeps its shape, so one side can be smaller."
        }
    }
}

enum ResizeCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }
}

struct SizePreset: Identifiable, Hashable {
    let name: String
    /// Nil for Custom.
    let size: CGSize?
    var id: String { name }

    var label: String {
        guard let size else { return name }
        return "\(name) (\(Int(size.width)) × \(Int(size.height)))"
    }

    static let custom = SizePreset(name: "Custom", size: nil)
    static let all: [SizePreset] = [
        SizePreset(name: "4K", size: CGSize(width: 3840, height: 2160)),
        SizePreset(name: "1440p", size: CGSize(width: 2560, height: 1440)),
        SizePreset(name: "1080p", size: CGSize(width: 1920, height: 1080)),
        SizePreset(name: "720p", size: CGSize(width: 1280, height: 720)),
        SizePreset(name: "480p", size: CGSize(width: 854, height: 480)),
        SizePreset(name: "Square", size: CGSize(width: 1080, height: 1080)),
        SizePreset(name: "Vertical", size: CGSize(width: 1080, height: 1920)),
        custom,
    ]
}

struct ResizeSettings: Equatable {
    var width = 1920
    var height = 1080
    var keepAspect = true
    var fit = ResizeFit.blackBars
    var codec = ResizeCodec.h264
}

/// How a source picture is placed in the output frame. Pure arithmetic, so it can be tested without video.
enum ResizePlan {
    struct Layout: Equatable {
        let renderSize: CGSize
        let scaleX: CGFloat
        let scaleY: CGFloat
        /// Where the scaled picture's top-left corner lands in the frame (negative when cropping).
        let offset: CGPoint
    }

    /// Video encoders need even dimensions, so odd sizes round down.
    static func even(_ n: CGFloat) -> CGFloat { max(2, (n / 2).rounded(.down) * 2) }

    static func layout(source: CGSize, settings: ResizeSettings) -> Layout {
        let src = CGSize(width: max(abs(source.width), 1), height: max(abs(source.height), 1))
        var target = CGSize(width: even(CGFloat(settings.width)), height: even(CGFloat(settings.height)))
        guard settings.keepAspect else {
            return Layout(renderSize: target, scaleX: target.width / src.width, scaleY: target.height / src.height, offset: .zero)
        }
        let fitScale = min(target.width / src.width, target.height / src.height)
        let fillScale = max(target.width / src.width, target.height / src.height)
        let scale: CGFloat
        switch settings.fit {
        case .blackBars: scale = fitScale
        case .crop: scale = fillScale
        case .within:
            scale = fitScale
            target = CGSize(width: even(src.width * scale), height: even(src.height * scale))
        }
        let scaled = CGSize(width: src.width * scale, height: src.height * scale)
        // Rounding the output to even sizes can leave a hair of mismatch; scale by the exact rendered size instead.
        let (sx, sy) = settings.fit == .within ? (target.width / src.width, target.height / src.height) : (scale, scale)
        let offset = settings.fit == .within ? CGPoint.zero
            : CGPoint(x: ((target.width - scaled.width) / 2).rounded(), y: ((target.height - scaled.height) / 2).rounded())
        return Layout(renderSize: target, scaleX: sx, scaleY: sy, offset: offset)
    }
}
