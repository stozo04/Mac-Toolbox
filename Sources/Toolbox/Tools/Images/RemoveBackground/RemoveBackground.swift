import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum RemoveBackgroundError: LocalizedError {
    case unreadable
    case noSubject
    case detectionFailed
    case renderFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .noSubject: "No subject was found in this photo."
        case .detectionFailed: "The subject could not be looked for in this photo."
        case .renderFailed: "The cutout could not be made."
        case .saveFailed: "The cutout could not be saved."
        }
    }
}

enum CutoutBackground: String, CaseIterable, Identifiable {
    case transparent, white, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transparent: "Transparent"
        case .white: "White"
        case .custom: "Color"
        }
    }

    /// What the cutout is called in the preview, e.g. "Transparent PNG".
    var kind: String {
        switch self {
        case .transparent: "Transparent PNG"
        case .white: "White PNG"
        case .custom: "Color PNG"
        }
    }
}

struct RemoveBackgroundSettings: Equatable {
    var background = CutoutBackground.transparent
    var customColor = RGBColor(red: 0.20, green: 0.45, blue: 0.95)
    var cropToSubject = false
}

struct RemoveBackgroundResult: Equatable {
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int64
}

/// Lifts the subject out of photos with Vision's foreground mask and saves it as a PNG, all on this Mac. The mask is
/// grayscale: white is the subject, black is the background.
enum RemoveBackground {
    private static let context = CIContext()
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Cutout

    /// The upright photo with its background replaced, at the photo's own size, or cropped to the subject when asked.
    static func cutout(_ image: CGImage, settings: RemoveBackgroundSettings) throws -> CGImage {
        let mask = try subjectMask(in: image)
        guard let cut = compose(image, mask: mask, settings: settings) else { throw RemoveBackgroundError.renderFailed }
        guard settings.cropToSubject, let bounds = subjectBounds(of: mask), let cropped = cut.cropping(to: bounds) else { return cut }
        return cropped
    }

    /// Apple's foreground mask for the photo, the same size as the photo.
    static func subjectMask(in image: CGImage) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw RemoveBackgroundError.detectionFailed }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw RemoveBackgroundError.noSubject }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        } catch {
            throw RemoveBackgroundError.detectionFailed
        }
        let mask = CIImage(cvPixelBuffer: buffer)
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        return mask.transformed(by: CGAffineTransform(scaleX: w / mask.extent.width, y: h / mask.extent.height))
    }

    /// The photo with everything the mask leaves out replaced by the chosen background. Where the mask is white the
    /// photo shows; where it is black the background does.
    static func compose(_ image: CGImage, mask: CIImage, settings: RemoveBackgroundSettings) -> CGImage? {
        let extent = CIImage(cgImage: image).extent
        let background: CIImage
        switch settings.background {
        case .transparent:
            background = CIImage(color: CIColor.clear)
        case .white:
            background = CIImage(color: CIColor.white)
        case .custom:
            let c = settings.customColor
            background = CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue))
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(cgImage: image)
        blend.backgroundImage = background.cropped(to: extent)
        blend.maskImage = mask
        guard let out = blend.outputImage else { return nil }
        return context.createCGImage(out, from: extent, format: .RGBA8, colorSpace: srgb)
    }

    /// The smallest rectangle, in pixels from the top left, that holds every part of the mask that is at least half white.
    static func subjectBounds(of mask: CIImage) -> CGRect? {
        let gray = CGColorSpaceCreateDeviceGray()
        guard let image = context.createCGImage(mask, from: mask.extent, format: .L8, colorSpace: gray) else { return nil }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let bitmap = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                         space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var (minX, minY, maxX, maxY) = (w, h, -1, -1)
        for y in 0..<h {
            for x in 0..<w where bytes[y * w + x] >= 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: Previews and saving

    /// The photo as it would be saved, scaled down to `maxSize` on its longer side.
    static func preview(of url: URL, settings: RemoveBackgroundSettings, maxSize: CGFloat = 1000) throws -> CGImage {
        guard let photo = ImageConverter.thumbnail(of: url, maxSize: maxSize) else { throw RemoveBackgroundError.unreadable }
        return try cutout(photo, settings: settings)
    }

    /// A new PNG of the photo with its background replaced, in `folder`. Transparent areas are kept, which JPEG cannot do.
    /// The original is never touched, and the copy has no metadata: location and camera details are left out.
    static func save(source: URL, settings: RemoveBackgroundSettings, into folder: URL) throws -> RemoveBackgroundResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw RemoveBackgroundError.unreadable }
        let upright = try ImageConverter.pixels(of: image, orientation: orientation(of: reader), flattenAlpha: false).image
        let cut = try cutout(upright, settings: settings)

        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: "png")
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RemoveBackgroundError.saveFailed
        }
        CGImageDestinationAddImage(writer, cut, nil)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: output)
            throw RemoveBackgroundError.saveFailed
        }
        return RemoveBackgroundResult(url: output, width: cut.width, height: cut.height, bytes: fileSize(output))
    }

    // MARK: Helpers

    /// The EXIF orientation tag (1 to 8); 1 when there is none.
    private static func orientation(of reader: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        return (properties[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
