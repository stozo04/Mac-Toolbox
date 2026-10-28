import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum FaceBlurError: LocalizedError {
    case unreadable
    case detectionFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .detectionFailed: "Faces could not be looked for in this photo."
        case .saveFailed: "The photo could not be saved with its faces hidden."
        }
    }
}

enum FaceBlurStyle: String, CaseIterable, Identifiable {
    case blur, pixelate, blackBox

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .blackBox: "Black Box"
        }
    }
}

struct FaceBlurSettings: Equatable {
    var style = FaceBlurStyle.blur
    /// 1 to 100: how far the blur or the pixels reach. Black Box always covers the face fully.
    var strength = 60
}

struct FaceBlurResult: Equatable {
    let url: URL
    /// Faces covered in this photo. Zero means the copy is the original, byte for byte.
    let facesHidden: Int
    let bytes: Int64
}

/// Finds faces with Vision and hides them, all on this Mac. Boxes are normalized to the upright photo with the
/// origin at the bottom left, which is how Vision reports them and how Core Image draws them.
enum FaceBlur {
    private static let context = CIContext()

    // MARK: Detection

    static func detectFaces(in url: URL) throws -> [CGRect] {
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw FaceBlurError.unreadable }
        let request = VNDetectFaceRectanglesRequest()
        do {
            let tag = CGImagePropertyOrientation(rawValue: UInt32(orientation(of: reader))) ?? .up
            try VNImageRequestHandler(cgImage: image, orientation: tag, options: [:]).perform([request])
        } catch {
            throw FaceBlurError.detectionFailed
        }
        return (request.results ?? []).map(\.boundingBox)
    }

    // MARK: Rendering

    /// The upright `image` with every face in `faces` covered. Returns `image` itself when there is nothing to cover.
    static func render(_ image: CGImage, faces: [CGRect], settings: FaceBlurSettings) -> CGImage? {
        guard !faces.isEmpty else { return image }
        let base = CIImage(cgImage: image)
        let extent = base.extent
        let t = Double(settings.strength) / 100
        var output = base
        for face in faces {
            let box = pixelRect(face, in: extent)
            let cover = margin(box).intersection(extent)
            let hidden: CIImage
            switch settings.style {
            case .blur:
                let radius = box.height * (0.08 + 0.5 * t)
                hidden = base.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: extent)
            case .pixelate:
                let block = max(4, box.height * (0.04 + 0.4 * t))
                hidden = base.applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: box.midX, y: box.midY),
                    kCIInputScaleKey: block,
                ])
            case .blackBox:
                hidden = CIImage(color: .black)
            }
            output = hidden.cropped(to: cover).composited(over: output)
        }
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
    }

    /// The face in pixels, with the origin at the bottom left.
    static func pixelRect(_ box: CGRect, in extent: CGRect) -> CGRect {
        CGRect(x: box.minX * extent.width, y: box.minY * extent.height, width: box.width * extent.width, height: box.height * extent.height)
    }

    /// The face plus a little extra margin, so hair and chin edges are covered too.
    static func margin(_ box: CGRect) -> CGRect {
        box.insetBy(dx: -box.width * 0.15, dy: -box.height * 0.2)
    }

    // MARK: Saving

    /// A new copy of the photo with `faces` hidden, in the photo's own format and upright. A photo with no faces to
    /// hide is copied byte for byte. The original is never touched.
    static func save(source: URL, faces: [CGRect], settings: FaceBlurSettings, into folder: URL) throws -> FaceBlurResult {
        let name = source.deletingPathExtension().lastPathComponent
        guard !faces.isEmpty else {
            let output = BatchFiles.uniqueURL(in: folder, name: name, ext: source.pathExtension)
            do { try FileManager.default.copyItem(at: source, to: output) } catch { throw FaceBlurError.saveFailed }
            return FaceBlurResult(url: output, facesHidden: 0, bytes: fileSize(output))
        }
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let type = CGImageSourceGetType(reader) as String?,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw FaceBlurError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let upright = try ImageConverter.pixels(of: image, orientation: orientation(of: reader), flattenAlpha: false).image
        guard let hidden = render(upright, faces: faces, settings: settings) else { throw FaceBlurError.saveFailed }

        // The photo's own format when ImageIO can write it; PNG otherwise (WebP, for example).
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        let keepsFormat = writable.contains(type)
        let writeType = keepsFormat ? type : UTType.png.identifier
        let output = BatchFiles.uniqueURL(in: folder, name: name, ext: keepsFormat ? source.pathExtension : "png")
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, writeType as CFString, 1, nil) else { throw FaceBlurError.saveFailed }
        var options = ImageConverter.keptProperties(properties)
        if writeType != UTType.png.identifier { options[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(writer, hidden, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: output)
            throw FaceBlurError.saveFailed
        }
        return FaceBlurResult(url: output, facesHidden: faces.count, bytes: fileSize(output))
    }

    // MARK: Helpers

    /// The EXIF orientation tag (1 to 8); 1 when there is none.
    static func orientation(of reader: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        return (properties[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
