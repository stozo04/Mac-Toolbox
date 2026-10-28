import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BeautifyError: LocalizedError {
    case unreadable
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .saveFailed: "The framed screenshot could not be saved."
        }
    }
}

enum BeautifyBackground: String, CaseIterable, Identifiable {
    case softLight, graphite, accentBlue, custom, image, transparent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .softLight: "Soft Light"
        case .graphite: "Graphite"
        case .accentBlue: "Accent Blue"
        case .custom: "Custom Color"
        case .image: "Image…"
        case .transparent: "Transparent"
        }
    }
}

enum BeautifyRatio: String, CaseIterable, Identifiable {
    case auto, widescreen, square, portrait, story

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .widescreen: "16:9 for X"
        case .square: "1:1 Square"
        case .portrait: "4:5 for Instagram"
        case .story: "9:16 for Stories"
        }
    }

    /// Width divided by height. Nil follows the framed screenshot.
    var aspect: CGFloat? {
        switch self {
        case .auto: nil
        case .widescreen: 16.0 / 9.0
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .story: 9.0 / 16.0
        }
    }
}

enum BeautifyShadow: String, CaseIterable, Identifiable {
    case none, soft, strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .soft: "Soft"
        case .strong: "Strong"
        }
    }

    /// Blur, drop and opacity as fractions of the screenshot's shorter side. Nil for no shadow.
    var geometry: (blur: CGFloat, drop: CGFloat, alpha: CGFloat)? {
        switch self {
        case .none: nil
        case .soft: (0.025, 0.012, 0.5)
        case .strong: (0.05, 0.025, 0.75)
        }
    }
}

struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double
}

struct BeautifySettings: Equatable {
    var background = BeautifyBackground.softLight
    var customColor = RGBColor(red: 0.20, green: 0.45, blue: 0.95)
    var imageURL: URL?
    var ratio = BeautifyRatio.auto
    /// 0 (S) to 1 (L).
    var padding = 0.4
    /// Points, roughly @2x. A screenshot's corners scale with its size.
    var cornerRadius = 12.0
    var shadow = BeautifyShadow.soft
}

struct BeautifyResult: Equatable {
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int64
}

/// Puts a screenshot on a background with padding, rounded corners and a shadow. Nothing is scaled up: the
/// screenshot keeps its own pixels and every size is measured from its shorter side.
enum BeautifyScreenshot {
    /// Preview of a screenshot as it would be saved, scaled down to `maxSize` on its longer side.
    static func preview(of url: URL, settings: BeautifySettings, maxSize: CGFloat = 1400) -> CGImage? {
        guard let shot = ImageConverter.thumbnail(of: url, maxSize: maxSize) else { return nil }
        let background = backgroundImage(settings, maxSize: maxSize)
        return frame(shot, settings: settings, background: background)
    }

    /// The screenshot's size, and a small copy for lists.
    static func inspect(_ url: URL) -> (size: CGSize, thumbnail: CGImage?) {
        var size = CGSize.zero
        if let reader = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            size = CGSize(width: w, height: h)
        }
        return (size, ImageConverter.thumbnail(of: url, maxSize: 120))
    }

    /// The background photo, downscaled for previews or full size for saving. Nil when none is chosen.
    static func backgroundImage(_ settings: BeautifySettings, maxSize: CGFloat?) -> CGImage? {
        guard settings.background == .image, let url = settings.imageURL else { return nil }
        if let maxSize { return ImageConverter.thumbnail(of: url, maxSize: maxSize) }
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(reader, 0, nil)
    }

    // MARK: Framing

    /// The upright screenshot framed on its background, at the screenshot's own resolution.
    static func frame(_ shot: CGImage, settings: BeautifySettings, background: CGImage?) -> CGImage? {
        let sw = CGFloat(shot.width), sh = CGFloat(shot.height)
        let unit = min(sw, sh)
        let pad = unit * (0.02 + 0.2 * settings.padding)
        let (cw, ch) = canvasSize(sw + 2 * pad, sh + 2 * pad, aspect: settings.ratio.aspect)
        let (w, h) = (Int(cw.rounded()), Int(ch.rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        paintBackground(ctx, canvas, settings: settings, image: background)

        let shotRect = CGRect(x: (cw - sw) / 2, y: (ch - sh) / 2, width: sw, height: sh)
        let radius = settings.cornerRadius * unit / 1100
        let path = CGPath(roundedRect: shotRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if let shadow = settings.shadow.geometry {
            // A solid shape under the screenshot casts the shadow; the screenshot covers it.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -unit * shadow.drop), blur: unit * shadow.blur,
                          color: CGColor(gray: 0, alpha: shadow.alpha))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(shot, in: shotRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// The canvas that holds the framed screenshot at the chosen aspect ratio. It only grows; nothing is cropped.
    static func canvasSize(_ fw: CGFloat, _ fh: CGFloat, aspect: CGFloat?) -> (CGFloat, CGFloat) {
        guard let aspect else { return (fw, fh) }
        if fw / fh > aspect { return (fw, fw / aspect) }
        return (fh * aspect, fh)
    }

    private static func paintBackground(_ ctx: CGContext, _ rect: CGRect, settings: BeautifySettings, image: CGImage?) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        switch settings.background {
        case .transparent:
            return
        case .custom:
            let c = settings.customColor
            ctx.setFillColor(CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1))
            ctx.fill(rect)
        case .image:
            if let image {
                // Fill the canvas, cropping the overflow from the middle.
                let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            } else {
                paintGradient(ctx, rect, top: BeautifyBackground.softLight.colors.top, bottom: BeautifyBackground.softLight.colors.bottom, space: space)
            }
        case .softLight, .graphite, .accentBlue:
            let colors = settings.background.colors
            paintGradient(ctx, rect, top: colors.top, bottom: colors.bottom, space: space)
        }
    }

    private static func paintGradient(_ ctx: CGContext, _ rect: CGRect, top: (Double, Double, Double), bottom: (Double, Double, Double), space: CGColorSpace) {
        let colors = [
            CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
            CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1),
        ]
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1]) else { return }
        // Top left to bottom right, since the origin is at the bottom left.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }

    // MARK: Saving

    /// A new PNG next to the others in `folder`. The original file is never touched.
    static func save(source: URL, settings: BeautifySettings, into folder: URL) throws -> BeautifyResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw BeautifyError.unreadable }
        let orientation = FaceBlur.orientation(of: reader)
        let upright = try ImageConverter.pixels(of: image, orientation: orientation, flattenAlpha: false).image
        guard let framed = frame(upright, settings: settings, background: backgroundImage(settings, maxSize: nil)) else {
            throw BeautifyError.saveFailed
        }

        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: "png")
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BeautifyError.saveFailed
        }
        CGImageDestinationAddImage(writer, framed, nil)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: output)
            throw BeautifyError.saveFailed
        }
        let bytes = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return BeautifyResult(url: output, width: framed.width, height: framed.height, bytes: bytes)
    }
}

extension BeautifyBackground {
    /// Top and bottom colors of the built-in gradients.
    var colors: (top: (Double, Double, Double), bottom: (Double, Double, Double)) {
        switch self {
        case .graphite: ((0.36, 0.37, 0.40), (0.13, 0.13, 0.15))
        case .accentBlue: ((0.42, 0.66, 1.0), (0.12, 0.33, 0.86))
        default: ((0.91, 0.95, 0.96), (0.78, 0.88, 0.87))
        }
    }
}
