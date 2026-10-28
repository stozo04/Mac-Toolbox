import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class RemoveMetadataTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remove-metadata-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: JPEG

    func testJPEGLosesEverythingPrivateAndKeepsItsPicture() throws {
        let source = try makePhoto(.jpeg, name: "trip.jpg", orientation: 1)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)

        XCTAssertEqual(result.removed, Set(MetadataKind.allCases))
        XCTAssertEqual(result.url.lastPathComponent, "trip.jpg")
        XCTAssertEqual(try typeOf(result.url), UTType.jpeg.identifier)
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertNil(try properties(result.url)[kCGImagePropertyGPSDictionary])
        XCTAssertNil(try properties(result.url)[kCGImagePropertyIPTCDictionary])
        for secret in Self.secrets { XCTAssertFalse(try bytes(result.url).contains(secret), "\(secret) is still in the file") }
        // Picture data is copied, not re-encoded: every pixel is identical.
        XCTAssertEqual(try pixels(result.url), try pixels(source))
    }

    func testJPEGKeepsOnlyTheRotationTag() throws {
        let source = try makePhoto(.jpeg, name: "sideways.jpg", orientation: 6)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(keepOrientation: true), into: out)

        XCTAssertEqual(try properties(result.url)[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertEqual(try dimensions(result.url).0, 400)
        XCTAssertEqual(try pixels(result.url), try pixels(source))
    }

    func testJPEGTurnedUprightWhenOrientationIsNotKept() throws {
        let source = try makePhoto(.jpeg, name: "sideways.jpg", orientation: 6)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(keepOrientation: false), into: out)

        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertNil(try properties(result.url)[kCGImagePropertyOrientation].flatMap { ($0 as? Int) == 1 ? nil : $0 })
        // Stored 400x300 with orientation 6 displays 300x400.
        XCTAssertEqual(try dimensions(result.url).0, 300)
        XCTAssertEqual(try dimensions(result.url).1, 400)
    }

    func testJPEGCommentSegmentIsDropped() throws {
        var data = try Data(contentsOf: makePhoto(.jpeg, name: "c.jpg", orientation: 1))
        let comment = Array("my home address".utf8)
        let length = UInt16(comment.count + 2)
        data.insert(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)] + comment, at: 2)
        let source = dir.appendingPathComponent("comment.jpg")
        try data.write(to: source)

        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)
        XCTAssertFalse(try bytes(result.url).contains("my home address"))
    }

    // MARK: Other formats

    func testPNGComesBackPixelForPixelWithoutDetails() throws {
        let source = try makePhoto(.png, name: "shot.png", orientation: 6)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)

        XCTAssertEqual(try typeOf(result.url), UTType.png.identifier)
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertEqual(try properties(result.url)[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try pixels(result.url), try pixels(source))
        for secret in Self.secrets { XCTAssertFalse(try bytes(result.url).contains(secret)) }
    }

    func testTIFFLosesItsDetails() throws {
        let source = try makePhoto(.tiff, name: "scan.tif", orientation: 1)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)

        XCTAssertEqual(try typeOf(result.url), UTType.tiff.identifier)
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertEqual(try pixels(result.url), try pixels(source))
    }

    func testHEICLosesItsDetailsAndStaysHEIC() throws {
        let source = try makePhoto(.heic, name: "iphone.heic", orientation: 6)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)

        XCTAssertEqual(try typeOf(result.url), UTType.heic.identifier)
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertEqual(try properties(result.url)[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(result.removed, Set(MetadataKind.allCases))
    }

    func testHEICTurnedUprightWhenOrientationIsNotKept() throws {
        let source = try makePhoto(.heic, name: "iphone.heic", orientation: 6)
        let result = try MetadataStripper.strip(source: source, settings: StripSettings(keepOrientation: false), into: out)
        XCTAssertEqual(try dimensions(result.url).0, 300)
        XCTAssertEqual(try dimensions(result.url).1, 400)
        XCTAssertTrue(try leftover(result.url).isEmpty)
    }

    func testWebPIsSavedLosslessWithoutDetails() throws {
        let png = try makePhoto(.png, name: "base.png", orientation: 1)
        let source = dir.appendingPathComponent("pic.webp")
        var settings = ConvertSettings(format: .webp, quality: 100)
        settings.losslessWebP = true
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil)), 0, nil))
        try ImageConverter.write(image, properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Test Lens"]], settings: settings, to: source)

        let result = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)
        XCTAssertEqual(result.url.pathExtension, "webp")
        XCTAssertTrue(try leftover(result.url).isEmpty)
        XCTAssertFalse(try bytes(result.url).contains("Test Lens"))
    }

    // MARK: Scanning and the rest

    func testScanNamesWhatAPhotoCarries() throws {
        let rich = try makePhoto(.jpeg, name: "rich.jpg", orientation: 6)
        XCTAssertEqual(MetadataStripper.scan(try XCTUnwrap(CGImageSourceCreateWithURL(rich as CFURL, nil))), Set(MetadataKind.allCases))

        let clean = try MetadataStripper.strip(source: rich, settings: StripSettings(), into: out).url
        XCTAssertEqual(MetadataStripper.scan(try XCTUnwrap(CGImageSourceCreateWithURL(clean as CFURL, nil))), [])
    }

    func testPhotoWithNothingToRemoveStillGetsACopy() throws {
        let plain = try makePhoto(.jpeg, name: "plain.jpg", orientation: 1, metadata: false)
        let result = try MetadataStripper.strip(source: plain, settings: StripSettings(), into: out)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testOriginalIsNeverTouched() throws {
        let source = try makePhoto(.jpeg, name: "orig.jpg", orientation: 6)
        let before = try Data(contentsOf: source)
        _ = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)
        _ = try MetadataStripper.strip(source: source, settings: StripSettings(keepOrientation: false), into: out)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testSameNameTwiceGetsANumber() throws {
        let source = try makePhoto(.jpeg, name: "twin.jpg", orientation: 1)
        let first = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)
        let second = try MetadataStripper.strip(source: source, settings: StripSettings(), into: out)
        XCTAssertEqual(first.url.lastPathComponent, "twin.jpg")
        XCTAssertEqual(second.url.lastPathComponent, "twin 2.jpg")
    }

    func testNotAnImageFailsWithoutLeavingAFile() throws {
        let fake = dir.appendingPathComponent("notes.jpg")
        try Data("hello".utf8).write(to: fake)
        XCTAssertThrowsError(try MetadataStripper.strip(source: fake, settings: StripSettings(), into: out))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @MainActor func testModelReadsWhatEachPhotoCarriesWhenAdded() throws {
        let model = RemoveMetadataModel()
        model.add([try makePhoto(.jpeg, name: "a.jpg", orientation: 1), try makePhoto(.jpeg, name: "b.jpg", orientation: 1, metadata: false)])
        XCTAssertEqual(model.items.map(\.found), [Set(MetadataKind.allCases), []])
        XCTAssertEqual(model.pendingKinds, Set(MetadataKind.allCases))
    }

    // MARK: Helpers

    private static let secrets = ["Acme", "Cam 9", "Test Lens", "secret note", "a caption", "Jane Doe", "2024:05:01"]

    /// A 400x300 gradient photo with location, camera, date, caption and author details.
    private func makePhoto(_ type: UTType, name: String, orientation: Int, metadata: Bool = true) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<10 {
            context.setFillColor(CGColor(red: CGFloat(i) / 10, green: 0.5, blue: 1 - CGFloat(i) / 10, alpha: 1))
            context.fill(CGRect(x: i * 40, y: 0, width: 40, height: 300))
        }
        var properties: [CFString: Any] = [:]
        if metadata {
            properties = [
                kCGImagePropertyOrientation: orientation,
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.77, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 122.4, kCGImagePropertyGPSLongitudeRef: "W"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                                 kCGImagePropertyExifLensModel: "Test Lens", kCGImagePropertyExifUserComment: "secret note"],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam 9",
                                                 kCGImagePropertyTIFFArtist: "Jane Doe", kCGImagePropertyTIFFOrientation: orientation],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "a caption"],
            ]
        } else if orientation != 1 {
            properties[kCGImagePropertyOrientation] = orientation
        }
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func reader(_ url: URL) throws -> CGImageSource { try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil)) }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(reader(url), 0, nil) as? [CFString: Any])
    }

    private func leftover(_ url: URL) throws -> Set<MetadataKind> { MetadataStripper.scan(try reader(url)) }

    private func typeOf(_ url: URL) throws -> String { try XCTUnwrap(CGImageSourceGetType(reader(url))) as String }

    private func dimensions(_ url: URL) throws -> (Int, Int) {
        let p = try properties(url)
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// The decoded pixels as stored (rotation tag not applied).
    private func pixels(_ url: URL) throws -> [UInt8] {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader(url), 0, nil))
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
}

private extension Data {
    func contains(_ text: String) -> Bool { range(of: Data(text.utf8)) != nil }
}
