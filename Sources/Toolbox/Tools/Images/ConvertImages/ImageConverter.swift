import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ConvertError: LocalizedError {
    case unreadable
    case saveFailed(ImageFormat)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .saveFailed(let format): "The image could not be saved as \(format.label)."
        }
    }
}

struct ConvertResult: Equatable {
    let url: URL
    let sourceBytes: Int64
    let bytes: Int64
}

/// Saves a copy of an image in another format. The original is never touched.
enum ImageConverter {
    static func convert(source: URL, settings: ConvertSettings, into folder: URL) throws -> ConvertResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ConvertError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1

        let format = settings.format
        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: format.ext)
        let kept = settings.keepMetadata ? keptProperties(properties) : [:]
        do {
            if format == .webp {
                try writeWebP(image, orientation: orientation, properties: kept, settings: settings, to: output)
            } else {
                try writeImageIO(image, orientation: orientation, properties: kept, settings: settings, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return ConvertResult(url: output, sourceBytes: fileSize(source), bytes: fileSize(output))
    }

    // MARK: ImageIO (HEIC, JPG, JPEG, PNG)

    private static func writeImageIO(_ image: CGImage, orientation: Int, properties: [CFString: Any], settings: ConvertSettings, to url: URL) throws {
        let format = settings.format
        guard let type = format.utType,
              let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw ConvertError.saveFailed(format) }
        let upright = try pixels(of: image, orientation: orientation, flattenAlpha: !format.supportsAlpha)
        var options = properties
        if format.isLossy { options[kCGImageDestinationLossyCompressionQuality] = Double(settings.quality) / 100 }
        CGImageDestinationAddImage(writer, upright.image, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw ConvertError.saveFailed(format) }
    }

    // MARK: WebP

    private static func writeWebP(_ image: CGImage, orientation: Int, properties: [CFString: Any], settings: ConvertSettings, to url: URL) throws {
        // WebP carries no color profile here, so the picture is written in sRGB.
        let upright = try pixels(of: image, orientation: orientation, flattenAlpha: false, space: CGColorSpace(name: CGColorSpace.sRGB))
        let (width, height) = (upright.image.width, upright.image.height)
        var buffer = try rgba(of: upright.image)
        defer { buffer.removeAll(keepingCapacity: false) }
        if upright.hasAlpha { unpremultiply(&buffer) }
        let data = try buffer.withUnsafeBytes {
            try WebPEncoder.encode(rgba: $0.baseAddress!, width: width, height: height, stride: width * 4, hasAlpha: upright.hasAlpha,
                                   quality: settings.quality, lossless: settings.losslessWebP, exif: exifBlock(properties))
        }
        do { try data.write(to: url, options: .atomic) } catch { throw ConvertError.saveFailed(.webp) }
    }

    // MARK: Pixels

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The picture turned upright as its orientation tag asks, in the image's own color space.
    /// With `flattenAlpha`, transparent areas become white (JPEG cannot hold transparency).
    static func pixels(of image: CGImage, orientation: Int, flattenAlpha: Bool, space: CGColorSpace? = nil) throws -> (image: CGImage, hasAlpha: Bool) {
        let alpha = hasAlpha(image) && !flattenAlpha
        let sourceSpace = image.colorSpace.flatMap { $0.model == .rgb || $0.model == .monochrome ? $0 : nil }
        let colorSpace = space ?? sourceSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if orientation == 1, !flattenAlpha || !hasAlpha(image), space == nil, image.colorSpace != nil { return (image, alpha) }

        // Draw as-is first, then move the pixels: moving bytes keeps every orientation exact.
        let (w, h) = (image.width, image.height)
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace.model == .monochrome ? CGColorSpace(name: CGColorSpace.sRGB)! : colorSpace,
                                      bitmapInfo: info.rawValue) else { throw ConvertError.unreadable }
        if flattenAlpha {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let drawn = context.makeImage() else { throw ConvertError.unreadable }
        guard orientation != 1 else { return (drawn, alpha) }
        guard let data = context.data else { throw ConvertError.unreadable }
        let (nw, nh) = orientation >= 5 ? (h, w) : (w, h)
        guard let out = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nw * 4, space: context.colorSpace!, bitmapInfo: info.rawValue),
              let target = out.data else { throw ConvertError.unreadable }
        let from = data.assumingMemoryBound(to: UInt32.self), to = target.assumingMemoryBound(to: UInt32.self)
        let srcStride = context.bytesPerRow / 4, dstStride = out.bytesPerRow / 4
        for y in 0..<h {
            for x in 0..<w {
                let (dx, dy) = destination(x: x, y: y, width: w, height: h, orientation: orientation)
                to[dy * dstStride + dx] = from[y * srcStride + x]
            }
        }
        guard let turned = out.makeImage() else { throw ConvertError.unreadable }
        return (turned, alpha)
    }

    /// Where a pixel of the stored picture lands once the EXIF orientation (1 to 8) is applied; rows count from the top.
    static func destination(x: Int, y: Int, width w: Int, height h: Int, orientation: Int) -> (Int, Int) {
        switch orientation {
        case 2: (w - 1 - x, y)
        case 3: (w - 1 - x, h - 1 - y)
        case 4: (x, h - 1 - y)
        case 5: (y, x)
        case 6: (h - 1 - y, x)
        case 7: (h - 1 - y, w - 1 - x)
        case 8: (y, w - 1 - x)
        default: (x, y)
        }
    }

    private static func rgba(of image: CGImage) throws -> [UInt8] {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let alpha = hasAlpha(image)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ConvertError.unreadable }
        return bytes
    }

    /// libwebp wants colors that are not multiplied by alpha.
    static func unpremultiply(_ bytes: inout [UInt8]) {
        var i = 0
        while i < bytes.count {
            let a = Int(bytes[i + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { bytes[i + c] = UInt8(min((Int(bytes[i + c]) * 255 + a / 2) / a, 255)) }
            }
            i += 4
        }
    }

    // MARK: Metadata

    /// Camera, date, location and caption details; leaves out what describes the old file (size, color model, orientation).
    static func keptProperties(_ source: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = source[key] { kept[key] = value }
        }
        if var exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = nil
            kept[kCGImagePropertyTIFFDictionary] = tiff
        }
        return kept
    }

    /// The EXIF block as WebP stores it: the TIFF data of a JPEG's APP1 segment, without the "Exif" prefix.
    static func exifBlock(_ properties: [CFString: Any]) -> Data? {
        let metadataKeys = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary]
        guard metadataKeys.contains(where: { properties[$0] != nil }) else { return nil }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let pixel = context.makeImage() else { return nil }
        CGImageDestinationAddImage(writer, pixel, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return nil }
        return exifSegment(inJPEG: data as Data)
    }

    static func exifSegment(inJPEG jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        var i = 2  // after the start-of-image marker
        while i + 4 <= bytes.count, bytes[i] == 0xFF {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xDA { break }  // start of scan: no more headers
            if marker == 0xE1, length > 8, i + 2 + length <= bytes.count, Array(bytes[(i + 4)..<(i + 10)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                return Data(bytes[(i + 10)..<(i + 2 + length)])
            }
            i += 2 + length
        }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
