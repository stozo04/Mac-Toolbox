import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class ConvertImagesTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("convert-images-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Every format to every format

    func testEveryFormatConvertsToEveryOtherFormat() throws {
        for from in ImageFormat.allCases {
            let source = try makeImage(format: from, name: "photo-\(from.ext)")
            for to in ImageFormat.allCases {
                let result = try ImageConverter.convert(source: source, settings: ConvertSettings(format: to, quality: 95), into: out)
                let label = "\(from.label) → \(to.label)"

                XCTAssertEqual(result.url.pathExtension, to.ext, label)
                XCTAssertEqual(result.url.deletingPathExtension().lastPathComponent.hasPrefix("photo-\(from.ext)"), true, label)
                XCTAssertGreaterThan(result.bytes, 0, label)
                try expectType(result.url, to, label)

                let image = try read(result.url)
                XCTAssertEqual([image.width, image.height], [64, 48], label)
                // The four quadrants keep their colors (lossy formats drift a little).
                try expectColor(image, 8, 6, (255, 0, 0), label + " top left")
                try expectColor(image, 56, 6, (0, 255, 0), label + " top right")
                try expectColor(image, 8, 42, (0, 0, 255), label + " bottom left")
                try expectColor(image, 56, 42, (255, 255, 0), label + " bottom right")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 25)
    }

    func testJpgAndJpegAreTheSameCodecWithDifferentExtensions() throws {
        let source = try makeImage(format: .png, name: "same")
        let jpg = try ImageConverter.convert(source: source, settings: ConvertSettings(format: .jpg), into: out)
        let jpeg = try ImageConverter.convert(source: source, settings: ConvertSettings(format: .jpeg), into: out)
        XCTAssertEqual([jpg.url.lastPathComponent, jpeg.url.lastPathComponent], ["same.jpg", "same.jpeg"])
        XCTAssertEqual(try Data(contentsOf: jpg.url), try Data(contentsOf: jpeg.url))
    }

    func testTheOriginalIsNeverChanged() throws {
        let source = try makeImage(format: .jpg, name: "keep")
        let before = try Data(contentsOf: source)
        for to in ImageFormat.allCases { _ = try ImageConverter.convert(source: source, settings: ConvertSettings(format: to), into: out) }
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testOtherFormatsMacOSReadsAlsoConvert() throws {
        let tiff = try makeImage(format: .png, name: "t", type: .tiff, ext: "tiff")
        let result = try ImageConverter.convert(source: tiff, settings: ConvertSettings(format: .webp), into: out)
        try expectType(result.url, .webp, "TIFF → WebP")
    }

    // MARK: Quality

    func testLowerQualityMakesSmallerFiles() throws {
        let source = try makeNoisyImage(name: "noise")
        for format in [ImageFormat.jpg, .heic, .webp] {
            let high = try ImageConverter.convert(source: source, settings: ConvertSettings(format: format, quality: 95), into: out)
            let low = try ImageConverter.convert(source: source, settings: ConvertSettings(format: format, quality: 20), into: out)
            XCTAssertLessThan(low.bytes, high.bytes, format.label)
        }
    }

    func testLosslessWebPKeepsEveryPixel() throws {
        let source = try makeNoisyImage(name: "exact")
        let original = try read(source)
        let result = try ImageConverter.convert(source: source, settings: ConvertSettings(format: .webp, losslessWebP: true), into: out)
        let copy = try read(result.url)
        XCTAssertEqual(try rgba(original), try rgba(copy))
    }

    // MARK: Transparency

    func testTransparencyIsKeptWhereTheFormatAllowsAndFlattenedToWhiteWhereItDoesNot() throws {
        let source = try makeImage(format: .png, name: "glass", transparent: true)
        for format in [ImageFormat.png, .webp] {
            let image = try read(try ImageConverter.convert(source: source, settings: ConvertSettings(format: format), into: out).url)
            let corner = try pixel(image, 8, 6)
            XCTAssertEqual(corner.a, 0, "\(format.label) keeps the see-through corner")
            XCTAssertEqual(try pixel(image, 56, 6).a, 255, "\(format.label) keeps the solid part opaque")
            try expectColor(image, 56, 6, (0, 255, 0), "\(format.label) solid part", tolerance: 4)
        }
        for format in [ImageFormat.jpg, .jpeg] {
            let image = try read(try ImageConverter.convert(source: source, settings: ConvertSettings(format: format, quality: 100), into: out).url)
            let corner = try pixel(image, 8, 6)
            XCTAssertGreaterThan(corner.r, 245); XCTAssertGreaterThan(corner.g, 245); XCTAssertGreaterThan(corner.b, 245)
        }
        let heic = try read(try ImageConverter.convert(source: source, settings: ConvertSettings(format: .heic, quality: 100), into: out).url)
        XCTAssertLessThan(try pixel(heic, 8, 6).a, 30, "HEIC keeps transparency")
    }

    // MARK: Orientation

    func testPhotosAreTurnedUprightForEveryFormat() throws {
        // Stored 64x48 with orientation 6 (rotate 90° clockwise to view): shown 48x64 with the red corner top right.
        let source = try makeImage(format: .jpg, name: "turned", orientation: 6)
        for to in ImageFormat.allCases {
            let image = try read(try ImageConverter.convert(source: source, settings: ConvertSettings(format: to, quality: 95), into: out).url)
            XCTAssertEqual([image.width, image.height], [48, 64], to.label)
            try expectColor(image, 40, 8, (255, 0, 0), "\(to.label) red top right")
            try expectColor(image, 40, 56, (0, 255, 0), "\(to.label) green bottom right")
            try expectColor(image, 8, 8, (0, 0, 255), "\(to.label) blue top left")
            XCTAssertEqual(orientationTag(of: image, url: out), nil)
        }
    }

    func testEveryOrientationMovesPixelsWhereExifSays() {
        // Stored image 3 wide, 2 high; where does the top-left pixel (0,0) and the bottom-right (2,1) go?
        let expectedTopLeft: [Int: (Int, Int)] = [1: (0, 0), 2: (2, 0), 3: (2, 1), 4: (0, 1), 5: (0, 0), 6: (1, 0), 7: (1, 2), 8: (0, 2)]
        let expectedBottomRight: [Int: (Int, Int)] = [1: (2, 1), 2: (0, 1), 3: (0, 0), 4: (2, 0), 5: (1, 2), 6: (0, 2), 7: (0, 0), 8: (1, 0)]
        for o in 1...8 {
            let a = ImageConverter.destination(x: 0, y: 0, width: 3, height: 2, orientation: o)
            let b = ImageConverter.destination(x: 2, y: 1, width: 3, height: 2, orientation: o)
            XCTAssertEqual([a.0, a.1], [expectedTopLeft[o]!.0, expectedTopLeft[o]!.1], "orientation \(o) top left")
            XCTAssertEqual([b.0, b.1], [expectedBottomRight[o]!.0, expectedBottomRight[o]!.1], "orientation \(o) bottom right")
        }
    }

    // MARK: Metadata

    func testKeepsOrRemovesCameraDateAndLocationInEveryFormat() throws {
        let source = try makeImage(format: .jpg, name: "geo", metadata: true)
        for to in ImageFormat.allCases {
            let kept = try ImageConverter.convert(source: source, settings: ConvertSettings(format: to, keepMetadata: true), into: out).url
            let stripped = try ImageConverter.convert(source: source, settings: ConvertSettings(format: to, keepMetadata: false), into: out).url
            XCTAssertTrue(try hasCameraAndLocation(kept), "\(to.label) keeps the details")
            XCTAssertFalse(try hasCameraAndLocation(stripped), "\(to.label) strips the details")
            XCTAssertFalse(try mentions(stripped, "TestCam"), "\(to.label) has no trace of the camera when stripped")
        }
    }

    func testKeptDetailsDoNotCarryTheOldSizeOrOrientation() {
        let source: [CFString: Any] = [
            kCGImagePropertyPixelWidth: 100, kCGImagePropertyColorModel: "RGB", kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Cam", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifPixelXDimension: 100, kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"],
        ]
        let kept = ImageConverter.keptProperties(source)
        XCTAssertNil(kept[kCGImagePropertyPixelWidth])
        XCTAssertNil(kept[kCGImagePropertyOrientation])
        let tiff = kept[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Cam")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFOrientation])
        let exif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifPixelXDimension])
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:01:02 03:04:05")
    }

    // MARK: Errors and files

    func testFilesThatAreNotImagesAreRefused() throws {
        let text = dir.appendingPathComponent("a.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ImageConverter.convert(source: text, settings: ConvertSettings(), into: out))
        XCTAssertThrowsError(try ImageConverter.convert(source: dir.appendingPathComponent("missing.png"), settings: ConvertSettings(), into: out))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing is left behind")
    }

    func testTwoImagesWithTheSameNameDoNotOverwriteEachOther() throws {
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        for d in [a, b] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try FileManager.default.copyItem(at: try makeImage(format: .png, name: "x"), to: a.appendingPathComponent("Shot.png"))
        try FileManager.default.copyItem(at: try makeImage(format: .png, name: "y"), to: b.appendingPathComponent("Shot.png"))
        for d in [a, b] { _ = try ImageConverter.convert(source: d.appendingPathComponent("Shot.png"), settings: ConvertSettings(format: .webp), into: out) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["Shot 2.webp", "Shot.webp"])
    }

    func testWebPBlocksAreWellFormed() throws {
        let source = try makeImage(format: .jpg, name: "riff", metadata: true)
        let data = try Data(contentsOf: try ImageConverter.convert(source: source, settings: ConvertSettings(format: .webp), into: out).url)
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WEBP")
        XCTAssertEqual(Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24, data.count - 8)
    }

    @MainActor func testQueueFindsImagesInFoldersAndSkipsDuplicates() throws {
        let sub = dir.appendingPathComponent("album")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let png = try makeImage(format: .png, name: "p")
        try FileManager.default.copyItem(at: png, to: sub.appendingPathComponent("one.png"))
        try FileManager.default.copyItem(at: png, to: sub.appendingPathComponent("two.PNG"))
        try "x".write(to: sub.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let model = ConvertImagesModel()
        model.add([sub, sub.appendingPathComponent("one.png"), dir.appendingPathComponent("a-missing.png")])
        XCTAssertEqual(model.items.map(\.url.lastPathComponent), ["one.png", "two.PNG"])
        XCTAssertEqual(model.items.first?.kind, "PNG")
        XCTAssertNotNil(model.notice, "the missing file is reported")
    }

    @MainActor func testQueueConvertsABatchIntoOneFolder() async throws {
        let model = ConvertImagesModel()
        model.settings.format = .webp
        model.add([try makeImage(format: .jpg, name: "one"), try makeImage(format: .heic, name: "two"), dir.appendingPathComponent("bad.txt")])
        try "x".write(to: dir.appendingPathComponent("bad.txt"), atomically: true, encoding: .utf8)
        model.add([dir.appendingPathComponent("bad.txt")])
        defer { if let f = model.folder { try? FileManager.default.removeItem(at: f) } }

        model.convert()
        for _ in 0..<200 where model.isRunning || model.items.contains(where: { $0.status == .waiting || $0.status == .converting }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.doneCount, 2)
        let folder = try XCTUnwrap(model.folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["one.webp", "two.webp"])
    }

    // MARK: Helpers

    private struct RGBA: Equatable { var r, g, b, a: Int }

    /// Four colored quadrants, optionally with a see-through top-left corner.
    private func quadrants(transparent: Bool = false) throws -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 24, width: 32, height: 24), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: transparent ? 0 : 1)),
            (CGRect(x: 32, y: 24, width: 32, height: 24), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 32, height: 24), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 32, y: 0, width: 32, height: 24), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
        ]
        for (rect, color) in colors { ctx.setFillColor(color); ctx.fill(rect) }
        return try XCTUnwrap(ctx.makeImage())
    }

    private func makeImage(format: ImageFormat, name: String, type: UTType? = nil, ext: String? = nil, transparent: Bool = false,
                           orientation: Int = 1, metadata: Bool = false) throws -> URL {
        let url = dir.appendingPathComponent("\(name).\(ext ?? format.ext)")
        let image = try quadrants(transparent: transparent)
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if orientation != 1 { properties[kCGImagePropertyOrientation] = orientation }
        if metadata {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "Model 7"]
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:03:14 10:20:30"]
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        if format == .webp {
            var bytes = try rgbaBytes(image)
            ConvertedFixtures.unpremultiply(&bytes)
            let data = try bytes.withUnsafeBytes {
                try WebPEncoder.encode(rgba: $0.baseAddress!, width: 64, height: 48, stride: 256, hasAlpha: transparent, quality: 100, lossless: true, exif: nil)
            }
            try data.write(to: url)
            return url
        }
        let utType = type ?? format.utType!
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer), "could not write the \(format.label) fixture")
        return url
    }

    /// Photographic-looking noise that compresses differently at different qualities.
    private func makeNoisyImage(name: String) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: 96 * 96 * 4)
        var seed: UInt32 = 12345
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for c in 0..<3 { seed = seed &* 1664525 &+ 1013904223; bytes[i + c] = UInt8(truncatingIfNeeded: seed >> 24) }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: 96, height: 96, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 384, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let url = dir.appendingPathComponent("\(name).png")
        let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func read(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) is not readable")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func expectType(_ url: URL, _ format: ImageFormat, _ label: String) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), label)
        let expected = format == .webp ? "org.webmproject.webp" : format.utType!.identifier
        XCTAssertEqual(CGImageSourceGetType(source) as String?, expected, label)
    }

    private func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] { try rgbaBytes(image) }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> RGBA {
        let bytes = try rgbaBytes(image)
        let i = (y * image.width + x) * 4
        let a = Int(bytes[i + 3])
        // Un-premultiply so a translucent pixel reports its own color.
        func un(_ v: UInt8) -> Int { a == 0 ? 0 : min(Int(v) * 255 / a, 255) }
        return RGBA(r: un(bytes[i]), g: un(bytes[i + 1]), b: un(bytes[i + 2]), a: a)
    }

    private func expectColor(_ image: CGImage, _ x: Int, _ y: Int, _ rgb: (Int, Int, Int), _ label: String, tolerance: Int = 40) throws {
        let p = try pixel(image, x, y)
        XCTAssertLessThanOrEqual(abs(p.r - rgb.0), tolerance, "\(label) red \(p)")
        XCTAssertLessThanOrEqual(abs(p.g - rgb.1), tolerance, "\(label) green \(p)")
        XCTAssertLessThanOrEqual(abs(p.b - rgb.2), tolerance, "\(label) blue \(p)")
    }

    private func orientationTag(of image: CGImage, url: URL) -> Int? {
        let file = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.first
        guard let file, let source = CGImageSourceCreateWithURL(url.appendingPathComponent(file) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let o = props[kCGImagePropertyOrientation] as? Int, o != 1 else { return nil }
        return o
    }

    private func hasCameraAndLocation(_ url: URL) throws -> Bool {
        if url.pathExtension == "webp" {
            // ImageIO may not surface WebP's EXIF; look for the chunk and the camera name inside it.
            return try mentions(url, "TestCam") && (try chunkTypes(url).contains("EXIF"))
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let make = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        return make == "TestCam" && gps?[kCGImagePropertyGPSLatitude] != nil
    }

    private func mentions(_ url: URL, _ text: String) throws -> Bool {
        try Data(contentsOf: url).range(of: Data(text.utf8)) != nil
    }

    private func chunkTypes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var types: [String] = [], i = 12
        while i + 8 <= data.count {
            types.append(String(decoding: data[i..<(i + 4)], as: UTF8.self))
            let size = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
            i += 8 + size + (size & 1)
        }
        return types
    }
}

private enum ConvertedFixtures {
    static func unpremultiply(_ bytes: inout [UInt8]) { ImageConverter.unpremultiply(&bytes) }
}
