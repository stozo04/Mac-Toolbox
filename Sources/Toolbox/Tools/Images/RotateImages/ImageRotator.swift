import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What is done to every photo: one of the eight ways a picture can be turned or mirrored in 90 degree steps.
/// Each click changes what you see, so the state is always "the picture as it looks now" and the buttons can be pressed in any order.
struct RotateSettings: Equatable {
    /// Clockwise quarter turns (0 to 3), applied after the mirror.
    private(set) var quarterTurns = 0
    /// Mirrored left to right before the turns.
    private(set) var mirrored = false

    var isIdentity: Bool { quarterTurns == 0 && !mirrored }
    /// A sideways turn swaps a photo's width and height.
    var swapsSides: Bool { quarterTurns % 2 == 1 }

    mutating func rotateRight() { quarterTurns = (quarterTurns + 1) % 4 }
    mutating func rotateLeft() { quarterTurns = (quarterTurns + 3) % 4 }
    /// Mirror what is on screen left to right. A mirror reverses the direction of the turns that were already made.
    mutating func flipHorizontal() { mirrored.toggle(); quarterTurns = (4 - quarterTurns) % 4 }
    /// Mirror what is on screen top to bottom: a left-right mirror and a half turn.
    mutating func flipVertical() { mirrored.toggle(); quarterTurns = (6 - quarterTurns) % 4 }
    mutating func reset() { self = RotateSettings() }

    /// The EXIF orientation (1 to 8) that describes the same change, so the pixel mover in `ImageConverter` does the work.
    var orientation: Int {
        mirrored ? [2, 7, 4, 5][quarterTurns] : [1, 6, 3, 8][quarterTurns]
    }

    /// The photo's size after the change.
    func output(for size: PixelSize) -> PixelSize {
        swapsSides ? PixelSize(width: size.height, height: size.width) : size
    }

    /// The "Result" line: "No change", "Right 90°", "Flip horizontal"...
    var summary: String {
        switch (mirrored, quarterTurns) {
        case (false, 0): "No change"
        case (false, 1): "Right 90°"
        case (false, 2): "180°"
        case (false, 3): "Left 90°"
        case (true, 0): "Flip horizontal"
        case (true, 2): "Flip vertical"
        case (true, 1): "Flip + right 90°"
        default: "Flip + left 90°"
        }
    }
}

struct RotateResult: Equatable {
    let url: URL
    let sourceBytes: Int64
    let bytes: Int64
    let from: PixelSize
    let to: PixelSize
}

enum RotateError: LocalizedError {
    case unreadable
    case animated
    case nothingToDo
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .animated: "Animated GIFs can't be rotated here."
        case .nothingToDo: "Choose a rotation or a flip first."
        case .saveFailed: "The rotated image could not be saved."
        }
    }
}

/// Saves a rotated or flipped copy of an image. The original is never touched.
enum ImageRotator {
    /// Encoder quality for the lossy formats. The copy is saved once more, so it stays high.
    private static let jpegQuality = 95, heicQuality = 90, webpQuality = 90

    /// The picture with `settings` applied. Pixels are moved, never resampled.
    static func apply(_ settings: RotateSettings, to image: CGImage) throws -> CGImage {
        guard !settings.isIdentity else { return image }
        return try ImageConverter.pixels(of: image, orientation: settings.orientation, flattenAlpha: false).image
    }

    static func rotate(source: URL, settings: RotateSettings, into folder: URL) throws -> RotateResult {
        guard !settings.isIdentity else { throw RotateError.nothingToDo }
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let original = ImageResizer.pixelSize(of: source) else { throw RotateError.unreadable }
        let type = CGImageSourceGetType(reader).flatMap { UTType($0 as String) }
        if CGImageSourceGetCount(reader) > 1, type?.conforms(to: .gif) == true { throw RotateError.animated }
        guard let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw RotateError.unreadable
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let upright = try ImageConverter.pixels(of: image, orientation: (properties[kCGImagePropertyOrientation] as? Int) ?? 1, flattenAlpha: false).image
        let turned = try apply(settings, to: upright)
        let expected = settings.output(for: original)

        let kept = ImageConverter.keptProperties(properties)
        let name = source.deletingPathExtension().lastPathComponent
        let output: URL
        do {
            if let format = ImageResizer.format(for: type, ext: source.pathExtension) {
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: format.ext)
                try ImageConverter.write(turned, properties: kept, settings: ConvertSettings(format: format, quality: quality(of: format), keepMetadata: true), to: output)
            } else if let type, (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true {
                // TIFF, BMP and the like: ImageIO writes them in their own format.
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: source.pathExtension)
                try ImageResizer.writeGeneric(turned, type: type, properties: kept, to: output)
            } else {
                output = BatchFiles.uniqueURL(in: folder, name: name, ext: "png")
                try ImageConverter.write(turned, properties: kept, settings: ConvertSettings(format: .png, keepMetadata: true), to: output)
            }
        } catch {
            throw error is ConvertError || error is ImageResizeError ? RotateError.saveFailed : error
        }

        // Look at the saved copy: it has to open, and it has to have the turned shape.
        guard ImageResizer.pixelSize(of: output) == expected else {
            try? FileManager.default.removeItem(at: output)
            throw RotateError.saveFailed
        }
        return RotateResult(url: output, sourceBytes: fileSize(source), bytes: fileSize(output), from: original, to: expected)
    }

    private static func quality(of format: ImageFormat) -> Int {
        switch format {
        case .jpg, .jpeg: jpegQuality
        case .heic: heicQuality
        case .webp: webpQuality
        case .png: 100
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
