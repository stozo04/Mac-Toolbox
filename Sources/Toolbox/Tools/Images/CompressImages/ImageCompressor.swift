import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CompressLevel: String, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    /// Encoder quality (1 to 100). HEIC reaches the same look at a lower number than JPEG.
    func quality(heic: Bool) -> Int {
        switch self {
        case .low: heic ? 35 : 45
        case .medium: heic ? 50 : 65
        case .high: heic ? 70 : 82
        }
    }

    var blurb: String {
        switch self {
        case .low: "The smallest files. Some fine detail is lost."
        case .medium: "A good balance of size and quality."
        case .high: "Looks the same as the original, with smaller savings."
        }
    }
}

/// What the compressed copies are saved as.
enum CompressFormat: String, CaseIterable, Identifiable {
    case keep, jpeg, heic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keep: "Keep Format"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }
}

struct CompressSettings: Equatable {
    var level = CompressLevel.medium
    var format = CompressFormat.keep
    /// Camera, date and location details. Off by default: they add weight and can give away where a photo was taken.
    var keepMetadata = false
}

struct CompressResult: Equatable {
    enum Outcome: Equatable {
        case compressed
        /// Re-encoding would not have made the file smaller, so a copy of the original was saved.
        case alreadySmall
        /// The format can't be compressed here (GIF, BMP, TIFF...), so a copy of the original was saved.
        case unsupported
    }

    let url: URL
    let sourceBytes: Int64
    let bytes: Int64
    let outcome: Outcome

    var savedBytes: Int64 { max(sourceBytes - bytes, 0) }
}

enum CompressError: LocalizedError {
    case unreadable

    var errorDescription: String? { "This file is not an image macOS can read." }
}

/// Saves a smaller copy of an image. The original is never touched.
enum ImageCompressor {
    static func compress(source: URL, settings: CompressSettings, into folder: URL) throws -> CompressResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0 else { throw CompressError.unreadable }
        let sourceBytes = fileSize(source)
        let type = CGImageSourceGetType(reader).flatMap { UTType($0 as String) }
        let animated = CGImageSourceGetCount(reader) > 1 && type?.conforms(to: .gif) == true
        guard !animated, let target = target(for: type, source: source, settings: settings) else {
            return try copyOriginal(source, into: folder, sourceBytes: sourceBytes, outcome: .unsupported)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let convert = ConvertSettings(format: target, quality: settings.level.quality(heic: target == .heic),
                                      keepMetadata: settings.keepMetadata, dropUnusedAlpha: true)
        let result = try ImageConverter.convert(source: source, settings: convert, into: folder)

        // A copy that is not smaller is pointless, unless it is the one without the photo's location the user asked for.
        let removesLocation = !settings.keepMetadata && properties[kCGImagePropertyGPSDictionary] != nil
        if result.bytes >= sourceBytes && !removesLocation {
            try? FileManager.default.removeItem(at: result.url)
            return try copyOriginal(source, into: folder, sourceBytes: sourceBytes, outcome: .alreadySmall)
        }
        return CompressResult(url: result.url, sourceBytes: sourceBytes, bytes: result.bytes, outcome: .compressed)
    }

    /// The format to write, or nil when this image can't be compressed as it is.
    static func target(for type: UTType?, source: URL, settings: CompressSettings) -> ImageFormat? {
        switch settings.format {
        case .jpeg: return .jpg
        case .heic: return .heic
        case .keep:
            guard let type else { return nil }
            if type.conforms(to: .jpeg) { return source.pathExtension.lowercased() == "jpeg" ? .jpeg : .jpg }
            if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
            if type.conforms(to: .png) { return .png }
            if type.conforms(to: .webP) { return .webp }
            return nil
        }
    }

    private static func copyOriginal(_ source: URL, into folder: URL, sourceBytes: Int64, outcome: CompressResult.Outcome) throws -> CompressResult {
        let url = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
        return CompressResult(url: url, sourceBytes: sourceBytes, bytes: sourceBytes, outcome: outcome)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
