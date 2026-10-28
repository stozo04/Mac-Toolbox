import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum RedactError: LocalizedError {
    case unreadable
    case animated
    case findFailed
    case saveFailed
    case notClean

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not an image macOS can read."
        case .animated: "Animated images can't be redacted, because only one frame would be saved."
        case .findFailed: "This image could not be searched."
        case .saveFailed: "The image could not be saved with its regions covered."
        case .notClean: "The details could not be removed from this image, so no copy was saved."
        }
    }
}

enum RedactStyle: String, CaseIterable, Identifiable {
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

struct RedactSettings: Equatable {
    var style = RedactStyle.blur
    /// 1 to 100: how far the blur or the pixels reach. Black Box always covers fully.
    var strength = 60
    /// Leave location, camera and date details out of the copy.
    var removeMetadata = true
}

struct RedactResult: Equatable {
    let url: URL
    /// Regions covered in this copy.
    let regions: Int
    let bytes: Int64
}

/// What Find & Cover can add.
enum RedactFind: String, CaseIterable, Identifiable {
    case faces, text, sensitive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .faces: "Find Faces"
        case .text: "Find Text"
        case .sensitive: "Find Emails, Phones & Links"
        }
    }

    var symbol: String {
        switch self {
        case .faces: "face.dashed"
        case .text: "text.viewfinder"
        case .sensitive: "at"
        }
    }

    /// "1 face", "3 lines of text", "2 lines with an email, phone or link".
    func count(_ n: Int) -> String {
        switch self {
        case .faces: n == 1 ? "1 face" : "\(n) faces"
        case .text: n == 1 ? "1 line of text" : "\(n) lines of text"
        case .sensitive: n == 1 ? "1 line with an email, phone or link" : "\(n) lines with an email, phone or link"
        }
    }

    var nothing: String {
        switch self {
        case .faces: "No faces found"
        case .text: "No text found"
        case .sensitive: "No emails, phone numbers or links found"
        }
    }
}

/// Which sides of a region a drag is holding.
struct RedactEdges: OptionSet, Equatable {
    let rawValue: Int
    static let left = RedactEdges(rawValue: 1)
    static let right = RedactEdges(rawValue: 2)
    static let top = RedactEdges(rawValue: 4)
    static let bottom = RedactEdges(rawValue: 8)
}

/// What is under the pointer.
enum RedactHit: Equatable {
    case body(UUID)
    case edge(UUID, RedactEdges)
}

/// Covers parts of an image with a blur, a pixel mosaic or a black box, and finds things worth covering, all on this Mac.
///
/// Regions are rectangles normalized to the upright image (0 to 1 on both sides) with the origin at the top left, which
/// is how the canvas draws them. Core Image and Vision count from the bottom left; the conversion happens in here.
enum RedactImage {
    /// The smallest a region can be on either side, as a fraction of the image.
    static let minSide: CGFloat = 0.01

    private static let context = CIContext()

    // MARK: Geometry

    /// `rect` moved and, if needed, grown so it lies inside the image and is at least `minSide` wide and high.
    static func fitted(_ rect: CGRect) -> CGRect {
        let w = min(max(rect.width, minSide), 1), h = min(max(rect.height, minSide), 1)
        return CGRect(x: min(max(rect.minX, 0), 1 - w), y: min(max(rect.minY, 0), 1 - h), width: w, height: h)
    }

    /// The region dragged out between two points.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        fitted(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)))
    }

    /// `rect` shifted by `delta`, kept inside the image.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        CGRect(x: min(max(rect.minX + delta.width, 0), 1 - rect.width), y: min(max(rect.minY + delta.height, 0), 1 - rect.height),
               width: rect.width, height: rect.height)
    }

    /// `rect` with the held sides pulled to `point`. A side stops at the opposite one rather than crossing it.
    static func resized(_ rect: CGRect, edges: RedactEdges, to point: CGPoint) -> CGRect {
        let p = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        var (minX, maxX, minY, maxY) = (rect.minX, rect.maxX, rect.minY, rect.maxY)
        if edges.contains(.left) { minX = min(p.x, maxX - minSide) }
        if edges.contains(.right) { maxX = max(p.x, minX + minSide) }
        if edges.contains(.top) { minY = min(p.y, maxY - minSide) }
        if edges.contains(.bottom) { maxY = max(p.y, minY + minSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether `a` and `b` are mostly the same place: the overlap is most of the smaller one.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        guard !shared.isNull else { return false }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 && shared.width * shared.height / smaller > 0.7
    }

    /// What the pointer is on. `point` is normalized, `size` is the image's size on screen (so `tolerance` is in screen points).
    /// Edges win over bodies, and the smallest region wins, so a box inside a bigger one can still be reached.
    static func hit(at point: CGPoint, in regions: [(id: UUID, rect: CGRect)], size: CGSize, tolerance: CGFloat = 7) -> RedactHit? {
        let p = CGPoint(x: point.x * size.width, y: point.y * size.height)
        var edgeHit: (area: CGFloat, hit: RedactHit)?
        var bodyHit: (area: CGFloat, hit: RedactHit)?
        for region in regions {
            let r = CGRect(x: region.rect.minX * size.width, y: region.rect.minY * size.height,
                           width: region.rect.width * size.width, height: region.rect.height * size.height)
            let t = min(tolerance, min(r.width, r.height) / 3)
            guard r.insetBy(dx: -t, dy: -t).contains(p) else { continue }
            let inner = r.insetBy(dx: t, dy: t)
            let area = r.width * r.height
            if inner.contains(p) {
                if area < (bodyHit?.area ?? .infinity) { bodyHit = (area, .body(region.id)) }
                continue
            }
            var edges: RedactEdges = []
            if p.x < inner.minX { edges.insert(.left) }
            if p.x > inner.maxX { edges.insert(.right) }
            if p.y < inner.minY { edges.insert(.top) }
            if p.y > inner.maxY { edges.insert(.bottom) }
            if area < (edgeHit?.area ?? .infinity) { edgeHit = (area, .edge(region.id, edges)) }
        }
        return edgeHit?.hit ?? bodyHit?.hit
    }

    // MARK: Finding

    /// Regions for what `kind` looks for, in `url`'s upright image.
    static func find(_ kind: RedactFind, in url: URL) throws -> [CGRect] {
        switch kind {
        case .faces:
            // Vision's box is the face itself; the margin takes in hair and chin.
            return try FaceBlur.detectFaces(in: url).map { fitted(topLeft(FaceBlur.margin($0))) }
        case .text:
            return try textLines(in: url).map(\.box)
        case .sensitive:
            return try textLines(in: url).filter { isSensitive($0.text) }.map(\.box)
        }
    }

    struct TextLine: Equatable {
        let text: String
        /// Padded a little, so the descenders are covered too.
        let box: CGRect
    }

    /// Every line of text Vision can read.
    static func textLines(in url: URL) throws -> [TextLine] {
        // Reading at a capped size keeps big photos quick; the thumbnail is already upright.
        guard let image = ImageConverter.thumbnail(of: url, maxSize: 3072) else { throw RedactError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Addresses, emails and numbers are not words; "correcting" them would hide the wrong thing.
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { throw RedactError.findFailed }
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        return (request.results ?? []).compactMap { line in
            guard let text = line.topCandidates(1).first?.string else { return nil }
            let pad = line.boundingBox.height * h * 0.15
            let box = topLeft(line.boundingBox).insetBy(dx: -pad / w, dy: -pad / h)
            return TextLine(text: text, box: fitted(box))
        }
    }

    /// True when the line holds an email address, a phone number or a link.
    static func isSensitive(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue),
           detector.firstMatch(in: line, options: [], range: range) != nil { return true }
        return line.range(of: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, options: .regularExpression) != nil
    }

    /// A Vision box (origin at the bottom left) as a region (origin at the top left).
    static func topLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    // MARK: Rendering

    /// `image` (upright) with every region covered. Returns `image` itself when there is nothing to cover.
    static func render(_ image: CGImage, regions: [CGRect], settings: RedactSettings) -> CGImage? {
        guard !regions.isEmpty else { return image }
        let base = CIImage(cgImage: image)
        let extent = base.extent
        let t = Double(settings.strength) / 100
        // Blur and pixel sizes follow the region (a line of text gets finer ones than a face), never smaller than a hair of the image.
        let floor = Double(max(extent.width, extent.height)) * 0.004
        var output = base
        for region in regions {
            let box = CGRect(x: region.minX * extent.width, y: (1 - region.maxY) * extent.height,
                             width: region.width * extent.width, height: region.height * extent.height).integral.intersection(extent)
            guard !box.isNull, box.width > 0, box.height > 0 else { continue }
            let unit = Double(min(box.width, box.height))
            let hidden: CIImage
            switch settings.style {
            case .blur:
                hidden = base.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(floor, unit * (0.1 + 0.6 * t))])
            case .pixelate:
                hidden = base.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputCenterKey: CIVector(x: box.minX, y: box.minY),
                    kCIInputScaleKey: max(floor, unit * (0.06 + 0.4 * t)),
                ])
            case .blackBox:
                hidden = CIImage(color: .black)
            }
            output = hidden.cropped(to: box).composited(over: output)
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: space)
    }

    // MARK: Reading

    /// The size of the upright image, or nil when it can't be read or is animated.
    static func inspect(_ url: URL) -> PixelSize? {
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              !isAnimated(reader),
              let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return FaceBlur.orientation(of: reader) >= 5 ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
    }

    /// GIF, PNG and WebP files with more than one frame. Saving one would silently keep only the first.
    static func isAnimated(_ reader: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(reader) > 1, let type = CGImageSourceGetType(reader).flatMap({ UTType($0 as String) }) else { return false }
        return type.conforms(to: .gif) || type.conforms(to: .png) || type.conforms(to: .webP)
    }

    // MARK: Saving

    /// A new copy of the image with `regions` covered, in the image's own format, upright and at full size. The original is never touched.
    /// The covered pixels are replaced in the copy, so nothing underneath can be recovered.
    static func save(source: URL, regions: [CGRect], settings: RedactSettings, into folder: URL) throws -> RedactResult {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) > 0,
              let type = CGImageSourceGetType(reader).flatMap({ UTType($0 as String) }),
              let image = CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw RedactError.unreadable }
        guard !isAnimated(reader) else { throw RedactError.animated }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any] ?? [:]
        let upright = try ImageConverter.pixels(of: image, orientation: FaceBlur.orientation(of: reader), flattenAlpha: false).image
        guard var covered = render(upright, regions: regions, settings: settings) else { throw RedactError.saveFailed }
        // The render always has an alpha channel; a picture that had none goes back without one (JPEG cannot hold it).
        if !ImageConverter.hasAlpha(upright) { covered = try ImageConverter.pixels(of: covered, orientation: 1, flattenAlpha: true).image }

        let name = source.deletingPathExtension().lastPathComponent
        let kept = settings.removeMetadata ? [:] : ImageConverter.keptProperties(properties)
        let isWebP = type.conforms(to: .webP)
        // The image's own format when ImageIO can write it (WebP goes through its own encoder); PNG otherwise.
        let keepsFormat = isWebP || ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(type.identifier)
        let output = BatchFiles.uniqueURL(in: folder, name: name, ext: keepsFormat ? source.pathExtension : "png")
        do {
            if isWebP {
                try ImageConverter.write(covered, properties: kept, settings: ConvertSettings(format: .webp, quality: 90, keepMetadata: !settings.removeMetadata), to: output)
            } else {
                guard let writer = CGImageDestinationCreateWithURL(output as CFURL, (keepsFormat ? type.identifier : UTType.png.identifier) as CFString, 1, nil)
                else { throw RedactError.saveFailed }
                var options = kept
                if keepsFormat, type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif) {
                    options[kCGImageDestinationLossyCompressionQuality] = 0.92
                }
                CGImageDestinationAddImage(writer, covered, options as CFDictionary)
                guard CGImageDestinationFinalize(writer) else { throw RedactError.saveFailed }
            }
            if settings.removeMetadata { try verifyClean(output) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return RedactResult(url: output, regions: regions.count, bytes: fileSize(output))
    }

    /// The saved copy must carry no location, camera or date details.
    private static func verifyClean(_ url: URL) throws {
        guard let copy = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(copy) > 0 else { throw RedactError.saveFailed }
        guard MetadataStripper.scan(copy).isEmpty else { throw RedactError.notClean }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
