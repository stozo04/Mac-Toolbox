import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class CompressImagesTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("compress-images-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Size

    func testJPEGGetsSmallerAndStaysAJPEG() throws {
        let source = try makeImage(.jpg, name: "photo", quality: 1.0)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)

        XCTAssertEqual(result.outcome, .compressed)
        XCTAssertLessThan(result.bytes, result.sourceBytes)
        XCTAssertEqual(result.sourceBytes, size(source))
        XCTAssertEqual(result.bytes, size(result.url))
        XCTAssertEqual(try typeOf(result.url), UTType.jpeg.identifier)
        XCTAssertEqual(result.url.pathExtension, "jpg")
        XCTAssertEqual(try dimensions(result.url).0, 400)
        XCTAssertEqual(try dimensions(result.url).1, 300)
    }

    func testLowIsSmallerThanMediumIsSmallerThanHigh() throws {
        let source = try makeImage(.jpg, name: "photo", quality: 1.0)
        var sizes: [Int64] = []
        for level in CompressLevel.allCases {
            let folder = out.appendingPathComponent(level.rawValue)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            sizes.append(try ImageCompressor.compress(source: source, settings: CompressSettings(level: level), into: folder).bytes)
        }
        XCTAssertLessThan(sizes[0], sizes[1])
        XCTAssertLessThan(sizes[1], sizes[2])
    }

    func testHEICIsReencodedAsHEIC() throws {
        let source = try makeImage(.heic, name: "photo", quality: 1.0)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)

        XCTAssertEqual(result.outcome, .compressed)
        XCTAssertLessThan(result.bytes, result.sourceBytes)
        XCTAssertEqual(try typeOf(result.url), UTType.heic.identifier)
    }

    func testPNGStaysLosslessAndLosesItsUnusedAlphaChannel() throws {
        let source = try makeImage(.png, name: "shot", opaqueAlphaChannel: true)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)

        XCTAssertEqual(result.outcome, .compressed)
        XCTAssertLessThan(result.bytes, result.sourceBytes)
        XCTAssertEqual(try typeOf(result.url), UTType.png.identifier)
        XCTAssertFalse(ImageConverter.hasAlpha(try read(result.url)))
        // Lossless: a pixel comes back exactly.
        XCTAssertEqual(try rgb(read(result.url), 17, 23).0, try rgb(read(source), 17, 23).0)
        XCTAssertEqual(try rgb(read(result.url), 17, 23).1, try rgb(read(source), 17, 23).1)
    }

    func testRealTransparencyIsKept() throws {
        let source = try makeImage(.png, name: "cutout", transparent: true)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)
        XCTAssertTrue(ImageConverter.hasAlpha(try read(result.url)))
        XCTAssertFalse(ImageConverter.isOpaque(try read(result.url)))
    }

    // MARK: Format

    func testChoosingHEICSavesAHEICFromAJPEG() throws {
        let source = try makeImage(.jpg, name: "photo", quality: 1.0)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(format: .heic), into: out)
        XCTAssertEqual(result.url.pathExtension, "heic")
        XCTAssertEqual(try typeOf(result.url), UTType.heic.identifier)
    }

    func testChoosingJPEGSavesAJPEGFromAPNG() throws {
        let source = try makeImage(.png, name: "photo")
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(format: .jpeg), into: out)
        XCTAssertEqual(result.outcome, .compressed)
        XCTAssertEqual(try typeOf(result.url), UTType.jpeg.identifier)
        XCTAssertLessThan(result.bytes, result.sourceBytes)
    }

    func testJPEGExtensionSpellingIsKept() throws {
        let long = try makeImage(.jpg, name: "long", ext: "jpeg", quality: 1.0)
        XCTAssertEqual(try ImageCompressor.compress(source: long, settings: CompressSettings(), into: out).url.pathExtension, "jpeg")
        let short = try makeImage(.jpg, name: "short", ext: "jpg", quality: 1.0)
        XCTAssertEqual(try ImageCompressor.compress(source: short, settings: CompressSettings(), into: out).url.pathExtension, "jpg")
    }

    // MARK: Originals kept

    func testAFileThatCannotGetSmallerIsCopiedAsIs() throws {
        // Saved at a very low quality already; re-encoding at High would only make it bigger.
        let source = try makeImage(.jpg, name: "squeezed", quality: 0.05)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(level: .high), into: out)

        XCTAssertEqual(result.outcome, .alreadySmall)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
        XCTAssertEqual(result.savedBytes, 0)
    }

    func testAGIFIsCopiedAsIs() throws {
        let source = try makeImage(.png, name: "icon", ext: "gif", type: .gif)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)
        XCTAssertEqual(result.outcome, .unsupported)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
    }

    func testOriginalsAreNeverTouched() throws {
        let source = try makeImage(.jpg, name: "photo", quality: 1.0)
        let before = try Data(contentsOf: source)
        _ = try ImageCompressor.compress(source: source, settings: CompressSettings(level: .low, format: .heic), into: out)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testSameNameTwiceDoesNotOverwrite() throws {
        let source = try makeImage(.jpg, name: "photo", quality: 1.0)
        let a = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)
        let b = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path))
    }

    func testAFileThatIsNotAnImageFails() throws {
        let url = dir.appendingPathComponent("notes.jpg")
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try ImageCompressor.compress(source: url, settings: CompressSettings(), into: out))
    }

    // MARK: Metadata

    func testMetadataIsRemovedUnlessKept() throws {
        let source = try makeImage(.jpg, name: "tagged", quality: 1.0, metadata: true)
        XCTAssertTrue(try hasLocation(source))

        let stripped = try ImageCompressor.compress(source: source, settings: CompressSettings(keepMetadata: false), into: out)
        XCTAssertFalse(try hasLocation(stripped.url))

        let kept = try ImageCompressor.compress(source: source, settings: CompressSettings(keepMetadata: true), into: out)
        XCTAssertTrue(try hasLocation(kept.url))
    }

    func testLocationIsStillRemovedWhenTheCleanCopyIsNotSmaller() throws {
        let source = try makeImage(.jpg, name: "tiny", flat: true, quality: 0.1, metadata: true)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(keepMetadata: false), into: out)
        XCTAssertEqual(result.outcome, .compressed)
        XCTAssertFalse(try hasLocation(result.url))
    }

    func testTheOrientationOfAPhotoIsAppliedNotLost() throws {
        // Stored 400 x 300 with orientation 6 (rotate right): shown 300 x 400.
        let source = try makeImage(.jpg, name: "rotated", quality: 1.0, orientation: 6)
        let result = try ImageCompressor.compress(source: source, settings: CompressSettings(), into: out)
        XCTAssertEqual(try dimensions(result.url).0, 300)
        XCTAssertEqual(try dimensions(result.url).1, 400)
    }

    // MARK: Levels

    func testHEICNeedsALowerNumberThanJPEGForTheSameLook() {
        for level in CompressLevel.allCases {
            XCTAssertLessThan(level.quality(heic: true), level.quality(heic: false))
        }
    }

    // MARK: Helpers

    /// A photo-like picture: smooth color with a little noise, so JPEG and HEIC have something to compress.
    private func makeImage(_ format: ImageFormat, name: String, ext: String? = nil, transparent: Bool = false, opaqueAlphaChannel: Bool = false,
                           flat: Bool = false, quality: Double = 0.9, orientation: Int = 1, metadata: Bool = false, type: UTType? = nil) throws -> URL {
        let url = dir.appendingPathComponent("\(name).\(ext ?? format.ext)")
        let (w, h) = flat ? (16, 16) : (400, 300)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1664525 &+ 1013904223
                let noise = flat ? 0 : Int(seed >> 28) - 8
                let i = (y * w + x) * 4
                bytes[i] = UInt8(clamping: (flat ? 90 : x * 255 / w) + noise)
                bytes[i + 1] = UInt8(clamping: (flat ? 140 : y * 255 / h) + noise)
                bytes[i + 2] = UInt8(clamping: (flat ? 200 : (x + y) * 255 / (w + h)) + noise)
                bytes[i + 3] = transparent && x < w / 2 ? 0 : 255
            }
        }
        let withAlpha = transparent || opaqueAlphaChannel
        let image: CGImage = try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: (withAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let utType = type ?? format.utType ?? .png
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if orientation != 1 { properties[kCGImagePropertyOrientation] = orientation }
        if metadata {
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "TestCam"]
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.3349, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 122.009, kCGImagePropertyGPSLongitudeRef: "W"]
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func size(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }

    private func read(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) is not readable")
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func typeOf(_ url: URL) throws -> String? {
        CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))) as String?
    }

    private func dimensions(_ url: URL) throws -> (Int, Int) {
        let image = try read(url)
        return (image.width, image.height)
    }

    private func rgb(_ image: CGImage, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let i = (y * image.width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    private func hasLocation(_ url: URL) throws -> Bool {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return props[kCGImagePropertyGPSDictionary] != nil
    }
}
