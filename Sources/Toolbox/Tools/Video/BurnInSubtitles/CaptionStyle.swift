import AppKit

/// How burned-in captions look.
struct CaptionStyle: Equatable {
    enum Size: String, CaseIterable, Identifiable {
        case small = "Small", medium = "Medium", large = "Large"
        var id: String { rawValue }
        /// Text height as a share of the video's height.
        var fraction: CGFloat {
            switch self {
            case .small: 0.04
            case .medium: 0.055
            case .large: 0.075
            }
        }
    }

    enum Position: String, CaseIterable, Identifiable {
        case bottom = "Bottom", top = "Top"
        var id: String { rawValue }
    }

    enum Look: String, CaseIterable, Identifiable {
        case shadow = "White with Shadow", box = "White on Black Box"
        var id: String { rawValue }
    }

    var size = Size.medium
    var position = Position.bottom
    var look = Look.shadow
}

/// A caption drawn to a picture, and where it goes in the video frame (origin bottom left).
struct RenderedCaption {
    let image: CGImage
    let frame: CGRect
}

/// Draws caption text into an image the size of its text, at the video's own resolution.
enum CaptionRenderer {
    /// Share of the video's width a caption may fill before it wraps.
    static let maxWidthShare: CGFloat = 0.84
    /// Gap between the caption and the video's edge, as a share of its height.
    static let edgeShare: CGFloat = 0.05

    static func fontSize(style: CaptionStyle, videoHeight: CGFloat) -> CGFloat {
        max((videoHeight * style.size.fraction).rounded(), 10)
    }

    static func render(_ text: String, style: CaptionStyle, videoSize: CGSize) -> RenderedCaption? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let fontSize = fontSize(style: style, videoHeight: videoSize.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.06)
        shadow.shadowBlurRadius = fontSize * 0.14
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        if style.look == .shadow { attributes[.shadow] = shadow }

        let padX = style.look == .box ? fontSize * 0.45 : fontSize * 0.25
        let padY = fontSize * 0.2
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let limit = CGSize(width: videoSize.width * maxWidthShare - 2 * padX, height: .greatestFiniteMagnitude)
        let bounds = attributed.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = Int(ceil(bounds.width + 2 * padX)), height = Int(ceil(bounds.height + 2 * padY))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        if style.look == .box {
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: height), xRadius: fontSize * 0.25, yRadius: fontSize * 0.25).fill()
        }
        attributed.draw(with: NSRect(x: padX, y: padY, width: CGFloat(width) - 2 * padX, height: CGFloat(height) - 2 * padY),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }

        let edge = videoSize.height * edgeShare
        let x = ((videoSize.width - CGFloat(width)) / 2).rounded()
        let y = style.position == .bottom ? edge : videoSize.height - edge - CGFloat(height)
        return RenderedCaption(image: image, frame: CGRect(x: x, y: y.rounded(), width: CGFloat(width), height: CGFloat(height)))
    }
}
