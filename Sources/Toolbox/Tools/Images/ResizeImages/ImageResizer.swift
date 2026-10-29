import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ResizeMode: String, CaseIterable, Identifiable {
    case percentage, longestSide, size

    var id: String { rawValue }
    var label: String {
        switch self {
        case .percentage: "Percentage"
        case .longestSide: "Longest Side"
        case .size: "Size"
        }
    }
}

struct PixelSize: Equatable {
    var width: Int
    var height: Int

    var longest: Int { max(width, height) }
}

struct ImageResizeSettings: Equatable {
    /// Largest value any field accepts, in pixels.
    static let maxPixels = 30_000
    static let percentRange = 1...1000

    var mode = ResizeMode.longestSide
    var percent = 50
    var longestSide = 1920
    var width = 1920
    var height = 1080
    /// Size only: keep each photo's shape and fit it inside the width and height. Off stretches to exactly that size.
    var keepProportions = true
    /// Let photos smaller than the target grow. Off leaves them at their size.
    var enlarge = false
}

/// What size a photo ends up at. Pure arithmetic, so the preview and the saved copy always agree.
enum ImageResizePlan {
    static func output(for original: PixelSize, settings s: ImageResizeSettings) -> PixelSize {
        guard original.width > 0, original.height > 0 else { return original }
        switch s.mode {
        case .percentage:
            return scaled(original, by: Double(s.percent) / 100)
        case .longestSide:
            return scaled(original, by: limited(Double(s.longestSide) / Double(original.longest), enlarge: s.enlarge))
        case .size:
            if s.keepProportions {
                let fit = min(Double(s.width) / Double(original.width), Double(s.height) / Double(original.height))
                return scaled(original, by: limited(fit, enlarge: s.enlarge))
            }
            // Stretched to exactly this size; without Enlarge, a side never grows.
            let w = s.enlarge ? s.width : min(s.width, original.width)
            let h = s.enlarge ? s.height : min(s.height, original.height)
            return PixelSize(width: max(w, 1), height: max(h, 1))
        }
    }

    private static func limited(_ factor: Double, enlarge: Bool) -> Double { factor > 1 && !enlarge ? 1 : factor }

    private static func scaled(_ size: PixelSize, by factor: Double) -> PixelSize {
        guard factor != 1 else { return size }
        return PixelSize(width: max(Int((Double(size.width) * factor).rounded()), 1),
                         height: max(Int((Double(size.height) * factor).rounded()), 1))
    }
}

struct ImageResizeResult: Equatable {
    enum Outcome: Equatable {
        case resized
        /// The photo already has the target size, so a copy of the original was saved.
        case unchanged
    }

    let url: URL
    let sourceBytes: Int64
    let bytes: Int64
    let from: PixelSize
    let to: PixelSize
    let outcome: Outcome
}

enum ImageResizeError: LocalizedError {
    case unreadable
    case animated
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .animated: "Animated GIFs can't be resized here."
        case .saveFailed: "The resized image could not be saved."
        }
    }
}

/// Saves a resized copy of an image. The original is never touched.
enum ImageResizer {
    /// Encoder quality for the lossy formats. A resized copy is re-encoded once, so it stays high.
    private static let jpegQuality = 90, heicQuality = 80, webpQuality = 85

    /// The photo's size as it is shown (turned upright), or nil when macOS can't read the file.
    static func pixelSize(of url: URL) -> PixelSize? {
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(reader) > 0 else { return nil }
        return pixelSize(of: reader)
    }

    private static func pixelSize(of reader: CGImageSource) -> PixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let turned = ((properties[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return turned ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
    }

    static func resize(source: URL, settings: ImageResizeSettings, into folder: URL) throws -> ImageResizeResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let original = pixelSize(of: reader) else { throw ImageResizeError.unreadable }
        let type = CGImageSourceGetType(reader).flatMap { UTType($0 as String) }
        if CGImageSourceGetCount(reader) > 1, type?.conforms(to: .gif) == true { throw ImageResizeError.animated }

        let sourceBytes = fileSize(source)
        let target = ImageResizePlan.output(for: original, settings: settings)
        guard target != original else {
            let url = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
            try FileManager.default.copyItem(at: source, to: url)
            return ImageResizeResult(url: url, sourceBytes: sourceBytes, bytes: sourceBytes, from: original, to: original, outcome: .unchanged)
        }

        guard let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ImageResizeError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let upright = try ImageConverter.pixels(of: image, orientation: (properties[kCGImagePropertyOrientation] as? Int) ?? 1, flattenAlpha: false).image
        guard let small = scale(upright, to: target) else { throw ImageResizeError.saveFailed }

        let kept = ImageConverter.keptProperties(properties)
        let name = source.deletingPathExtension().lastPathComponent
        let output: URL
        do {
            if let format = format(for: type, ext: source.pathExtension) {
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: format.ext)
                let convert = ConvertSettings(format: format, quality: quality(of: format), keepMetadata: true)
                try ImageConverter.write(small, properties: kept, settings: convert, to: output)
            } else if let type, (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true {
                // TIFF, BMP and the like: ImageIO writes them in their own format.
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: source.pathExtension)
                try writeGeneric(small, type: type, properties: kept, to: output)
            } else {
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: "png")
                try ImageConverter.write(small, properties: kept, settings: ConvertSettings(format: .png, keepMetadata: true), to: output)
            }
        } catch {
            throw error is ConvertError ? ImageResizeError.saveFailed : error
        }
        return ImageResizeResult(url: output, sourceBytes: sourceBytes, bytes: fileSize(output), from: original, to: target, outcome: .resized)
    }

    // MARK: Scaling

    /// Scales in steps of at most half, which keeps big reductions sharp instead of jagged.
    static func scale(_ image: CGImage, to target: PixelSize) -> CGImage? {
        var current = image
        while current.width > target.width * 2 || current.height > target.height * 2 {
            let next = PixelSize(width: max(target.width, current.width / 2), height: max(target.height, current.height / 2))
            guard let smaller = draw(current, size: next) else { return nil }
            current = smaller
        }
        return draw(current, size: target)
    }

    private static func draw(_ image: CGImage, size: PixelSize) -> CGImage? {
        let source = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let space = source ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = ImageConverter.hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    // MARK: Saving

    /// The format a copy is saved in, or nil when the photo is not one of the five Toolbox writes itself.
    static func format(for type: UTType?, ext: String) -> ImageFormat? {
        guard let type else { return nil }
        if type.conforms(to: .jpeg) { return ext.lowercased() == "jpeg" ? .jpeg : .jpg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .webP) { return .webp }
        return nil
    }

    private static func quality(of format: ImageFormat) -> Int {
        switch format {
        case .jpg, .jpeg: jpegQuality
        case .heic: heicQuality
        case .webp: webpQuality
        case .png: 100
        }
    }

    static func writeGeneric(_ image: CGImage, type: UTType, properties: [CFString: Any], to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ImageResizeError.saveFailed }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: url)
            throw ImageResizeError.saveFailed
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
