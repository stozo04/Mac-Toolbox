import Foundation
import UniformTypeIdentifiers

/// The formats Convert Images can save.
enum ImageFormat: String, CaseIterable, Identifiable {
    case heic, webp, jpg, jpeg, png

    var id: String { rawValue }
    var ext: String { rawValue }

    var label: String {
        switch self {
        case .heic: "HEIC"
        case .webp: "WebP"
        case .jpg: "JPG"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    /// Lossless formats have no quality setting.
    var isLossy: Bool { self != .png }
    var supportsAlpha: Bool { self != .jpg && self != .jpeg }

    /// The type ImageIO writes; WebP is written by libwebp instead.
    var utType: UTType? {
        switch self {
        case .heic: .heic
        case .jpg, .jpeg: .jpeg
        case .png: .png
        case .webp: nil
        }
    }

    /// What a file with this extension is called in the list ("jpeg" and "jpg" both read "JPEG").
    static func name(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": "JPEG"
        case "heic", "heif": "HEIC"
        case "png": "PNG"
        case "webp": "WebP"
        case "tif", "tiff": "TIFF"
        case "gif": "GIF"
        case "bmp": "BMP"
        case "avif": "AVIF"
        default: ext.uppercased()
        }
    }
}

struct ConvertSettings: Equatable {
    var format = ImageFormat.jpg
    /// 1 to 100, for the lossy formats.
    var quality = 85
    /// Keep the camera, date and location details saved in the photo.
    var keepMetadata = true
    /// WebP only: no quality loss at all, at the cost of a bigger file.
    var losslessWebP = false
    /// Leave out the see-through channel when nothing in the picture is see-through (a smaller file that looks the same).
    var dropUnusedAlpha = false
}
