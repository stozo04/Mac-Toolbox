import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The kinds of private details a photo can carry.
enum MetadataKind: String, CaseIterable, Comparable {
    case location = "Location"
    case camera = "Camera"
    case dates = "Dates"
    case other = "Other details"

    static func < (a: MetadataKind, b: MetadataKind) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

struct StripSettings: Equatable {
    /// Keep the rotation tag so a photo taken sideways still opens the right way up.
    var keepOrientation = true
}

struct StripResult: Equatable {
    let url: URL
    let sourceBytes: Int64
    let bytes: Int64
    /// What the original carried and the copy does not.
    let removed: Set<MetadataKind>
}

enum StripError: LocalizedError {
    case unreadable
    case unsupported(String)
    case saveFailed
    case notClean

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .unsupported(let name): "\(name) photos can't be cleaned here. Convert it to JPEG or PNG first."
        case .saveFailed: "The clean copy could not be saved."
        case .notClean: "The details could not be removed from this photo, so no copy was saved."
        }
    }
}

/// Saves a copy of a photo without its location, camera, date and other embedded details. The original is never touched.
enum MetadataStripper {
    static func strip(source: URL, settings: StripSettings, into folder: URL) throws -> StripResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0 else { throw StripError.unreadable }
        let type = CGImageSourceGetType(reader).flatMap { UTType($0 as String) }
        let found = scan(reader)
        let orientation = orientation(of: reader)
        let output = BatchFiles.uniqueURL(in: folder, name: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)

        do {
            try write(reader, type: type, orientation: orientation, keepOrientation: settings.keepOrientation, to: output)
            try verify(output, orientation: settings.keepOrientation ? orientation : 1)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return StripResult(url: output, sourceBytes: fileSize(source), bytes: fileSize(output), removed: found)
    }

    // MARK: Reading

    /// What a photo carries, from its property dictionaries and its XMP. Orientation, size and color details do not count.
    static func scan(_ reader: CGImageSource) -> Set<MetadataKind> {
        var found = Set<MetadataKind>()
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any] ?? [:]
        for (group, value) in properties {
            guard let entries = value as? [String: Any] else { continue }
            for key in entries.keys { if let kind = kind(group: group, key: key) { found.insert(kind) } }
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(reader, 0, nil),
           let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
            for tag in tags {
                guard let name = CGImageMetadataTagCopyName(tag) as String?, let prefix = CGImageMetadataTagCopyPrefix(tag) as String? else { continue }
                if let kind = xmpKind(prefix: prefix, name: name) { found.insert(kind) }
            }
        }
        return found
    }

    private static func orientation(of reader: CGImageSource) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    /// Describes one entry of a property group such as {Exif}, {TIFF}, {GPS}, {IPTC} or {PNG}; nil for entries that only describe the picture.
    private static func kind(group: String, key: String) -> MetadataKind? {
        let structural: Set<String> = [
            "ColorSpace", "PixelXDimension", "PixelYDimension", "ComponentsConfiguration", "ExifVersion", "FlashPixVersion",
            "Orientation", "Compression", "PhotometricInterpretation", "ResolutionUnit", "XResolution", "YResolution",
            "TileWidth", "TileLength", "Headroom", "PrimaryImage",
        ]
        if structural.contains(key) { return nil }
        let isDate = key.localizedCaseInsensitiveContains("date") || key.hasPrefix("SubsecTime") || key.hasPrefix("OffsetTime")
            || key == "TimeCreated" || key == "CreationTime" || key == "ModificationTime"
        switch group {
        case "{GPS}": return .location
        case "{IPTC}": return isDate ? .dates : .other
        case "{TIFF}":
            if isDate { return .dates }
            return key == "Make" || key == "Model" ? .camera : .other
        case "{Exif}":
            if isDate { return .dates }
            return key == "UserComment" || key == "ImageUniqueID" ? .other : .camera
        case "{ExifAux}": return .camera
        case "{PNG}":
            if isDate { return .dates }
            return ["Author", "Description", "Software", "Title", "Copyright", "Comment", "Source", "Disclaimer", "Warning"].contains(key) ? .other : nil
        case "{Photoshop}": return .other
        default: return group.hasPrefix("{Maker") ? .camera : nil
        }
    }

    private static func xmpKind(prefix: String, name: String) -> MetadataKind? {
        if name.hasPrefix("has") { return nil }
        if ["Orientation", "ColorSpace", "PixelXDimension", "PixelYDimension", "Compression", "PhotometricInterpretation", "ResolutionUnit",
            "TileWidth", "TileLength", "XResolution", "YResolution"].contains(name) { return nil }
        if name.hasPrefix("GPS") || prefix == "Iptc4xmpExt" && name.contains("Location") { return .location }
        if name.localizedCaseInsensitiveContains("date") || name.hasPrefix("SubsecTime") || name.hasPrefix("OffsetTime") { return .dates }
        if ["Make", "Model", "LensModel", "LensMake", "SerialNumber", "BodySerialNumber", "LensSerialNumber", "CameraOwnerName"].contains(name)
            || prefix == "exif" || prefix == "exifEX" || prefix == "aux" { return .camera }
        return .other
    }

    // MARK: Writing

    private static func write(_ reader: CGImageSource, type: UTType?, orientation: Int, keepOrientation: Bool, to output: URL) throws {
        if type?.conforms(to: .jpeg) == true, keepOrientation || orientation == 1 {
            try copyJPEG(reader, orientation: keepOrientation ? orientation : 1, to: output)
        } else {
            try reencode(reader, type: type, orientation: orientation, keepOrientation: keepOrientation, to: output)
        }
    }

    /// JPEG photos are copied as they are, picture data untouched, with only the rotation tag put back.
    private static func copyJPEG(_ reader: CGImageSource, orientation: Int, to output: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw StripError.saveFailed }
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 { CGImageMetadataSetValueWithPath(metadata, nil, "tiff:Orientation" as CFString, String(orientation) as CFString) }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]
        guard CGImageDestinationCopyImageSource(writer, reader, options as CFDictionary, nil) else { throw StripError.saveFailed }
    }

    /// Other formats keep details in places ImageIO will not clear, so the picture is decoded and saved again with nothing attached.
    /// PNG and TIFF come back pixel for pixel; HEIC is saved at high quality.
    private static func reencode(_ reader: CGImageSource, type: UTType?, orientation: Int, keepOrientation: Bool, to output: URL) throws {
        guard let type else { throw StripError.unreadable }
        if type.conforms(to: .webP) { return try reencodeWebP(reader, orientation: orientation, to: output) }
        guard CGImageSourceGetCount(reader) == 1 else { throw StripError.unsupported("Animated") }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(type.identifier),
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw StripError.unsupported(type.localizedDescription.map { $0.capitalized } ?? "This") }

        var options: [CFString: Any] = [:]
        var picture = image
        if keepOrientation {
            if orientation != 1 { options[kCGImagePropertyOrientation] = orientation }
        } else if orientation != 1 {
            picture = try ImageConverter.pixels(of: image, orientation: orientation, flattenAlpha: type.conforms(to: .jpeg)).image
        }
        if type.conforms(to: .jpeg) { options[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { options[kCGImageDestinationLossyCompressionQuality] = 0.9 }

        guard let writer = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else { throw StripError.saveFailed }
        CGImageDestinationAddImage(writer, picture, options as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw StripError.saveFailed }
    }

    /// ImageIO cannot write WebP; the picture is turned upright and saved lossless through the WebP encoder, with no metadata.
    private static func reencodeWebP(_ reader: CGImageSource, orientation: Int, to output: URL) throws {
        guard CGImageSourceGetCount(reader) == 1,
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw StripError.unsupported("Animated") }
        let upright = try ImageConverter.pixels(of: image, orientation: orientation, flattenAlpha: false, space: CGColorSpace(name: CGColorSpace.sRGB))
        var settings = ConvertSettings(format: .webp, quality: 100, keepMetadata: false)
        settings.losslessWebP = true
        try ImageConverter.write(upright.image, properties: [:], settings: settings, to: output)
    }

    // MARK: Checking

    /// Looks at the saved copy: nothing private may be left, and a photo that was sideways must still be.
    private static func verify(_ url: URL, orientation: Int) throws {
        guard let copy = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(copy) > 0 else { throw StripError.saveFailed }
        guard scan(copy).isEmpty else { throw StripError.notClean }
        let type = CGImageSourceGetType(copy).flatMap { UTType($0 as String) }
        // WebP has no rotation tag here; its pixels are already upright.
        if type?.conforms(to: .webP) != true, self.orientation(of: copy) != orientation { throw StripError.saveFailed }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
