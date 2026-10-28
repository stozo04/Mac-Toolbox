import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class RedactImageTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("redact-image-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // A region in the middle: half of each side, origin at the top left.
    private let middle = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    // MARK: Geometry

    func testDraggedRegionIsNormalizedClampedAndNeverEmpty() {
        let dragged = RedactImage.rect(from: CGPoint(x: 0.6, y: 0.7), to: CGPoint(x: 0.2, y: 0.1))
        assertRect(dragged, 0.2, 0.1, 0.4, 0.6)
        let tiny = RedactImage.rect(from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(tiny.width, RedactImage.minSide, accuracy: 1e-9)
        let corner = RedactImage.rect(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 1, y: 1))
        XCTAssertEqual(corner.maxX, 1, accuracy: 1e-9, "a region at the edge is moved in, not pushed out of the image")
        XCTAssertEqual(corner.maxY, 1, accuracy: 1e-9)
    }

    func testMovingStaysInsideTheImage() {
        let moved = RedactImage.moved(middle, by: CGSize(width: 0.9, height: -0.9))
        XCTAssertEqual(moved, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
    }

    func testResizingPullsOnlyTheHeldSides() {
        let wider = RedactImage.resized(middle, edges: [.right, .bottom], to: CGPoint(x: 0.9, y: 0.95))
        XCTAssertEqual(wider, CGRect(x: 0.25, y: 0.25, width: 0.65, height: 0.7))
        let narrower = RedactImage.resized(middle, edges: .left, to: CGPoint(x: 0.4, y: 0.99))
        XCTAssertEqual(narrower, CGRect(x: 0.4, y: 0.25, width: 0.35, height: 0.5), "the other axis is untouched")
    }

    func testASideStopsAtTheOppositeOne() {
        let crushed = RedactImage.resized(middle, edges: .left, to: CGPoint(x: 0.95, y: 0))
        XCTAssertEqual(crushed.maxX, middle.maxX, accuracy: 1e-9)
        XCTAssertEqual(crushed.width, RedactImage.minSide, accuracy: 1e-9)
    }

    func testOverlapMeansMostOfTheSmallerRegion() {
        XCTAssertTrue(RedactImage.overlaps(middle, CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)), "inside a bigger region")
        XCTAssertTrue(RedactImage.overlaps(middle, middle))
        XCTAssertFalse(RedactImage.overlaps(middle, CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)), "a corner touch is not the same place")
        XCTAssertFalse(RedactImage.overlaps(middle, CGRect(x: 0, y: 0, width: 0.1, height: 0.1)))
    }

    func testHitPrefersEdgesThenTheSmallestRegion() {
        let big = (id: UUID(), rect: middle)
        let small = (id: UUID(), rect: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        let size = CGSize(width: 1000, height: 1000)

        XCTAssertEqual(RedactImage.hit(at: CGPoint(x: 0.5, y: 0.5), in: [big, small], size: size), .body(small.id))
        XCTAssertEqual(RedactImage.hit(at: CGPoint(x: 0.3, y: 0.3), in: [big, small], size: size), .body(big.id))
        XCTAssertEqual(RedactImage.hit(at: CGPoint(x: 0.2503, y: 0.5), in: [big, small], size: size), .edge(big.id, .left))
        XCTAssertEqual(RedactImage.hit(at: CGPoint(x: 0.7497, y: 0.2503), in: [big, small], size: size), .edge(big.id, [.right, .top]))
        XCTAssertNil(RedactImage.hit(at: CGPoint(x: 0.05, y: 0.05), in: [big, small], size: size))
    }

    func testTinyRegionsCanStillBeMoved() {
        // 4 pt wide on screen: the grab zone shrinks so the middle is still a body, not all edges.
        let tiny = (id: UUID(), rect: CGRect(x: 0.5, y: 0.5, width: 0.004, height: 0.004))
        XCTAssertEqual(RedactImage.hit(at: CGPoint(x: 0.502, y: 0.502), in: [tiny], size: CGSize(width: 1000, height: 1000)), .body(tiny.id))
    }

    func testVisionBoxesFlipToTheTopLeft() {
        // Vision counts y from the bottom, so a box near the top of the picture has a large y there and a small one here.
        let flipped = RedactImage.topLeft(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2))
        assertRect(flipped, 0.1, 0.1, 0.2, 0.2)
    }

    // MARK: Reading what is sensitive

    func testEmailsPhonesAndLinksAreSensitive() {
        XCTAssertTrue(RedactImage.isSensitive("Write to jane.doe@example.com today"))
        XCTAssertTrue(RedactImage.isSensitive("Call (415) 555-0134"))
        XCTAssertTrue(RedactImage.isSensitive("See https://example.com/private/page"))
        XCTAssertTrue(RedactImage.isSensitive("example.com/login"))
        XCTAssertFalse(RedactImage.isSensitive("Quarterly report draft"))
        XCTAssertFalse(RedactImage.isSensitive("Meeting at 5 with the team"))
    }

    // MARK: Hiding

    func testBlackBoxCoversTheRegionOnly() throws {
        let photo = try image(200, 100) { _, _ in (255, 0, 0) }

        let hidden = try XCTUnwrap(RedactImage.render(photo, regions: [middle], settings: RedactSettings(style: .blackBox)))
        let px = try rgba(hidden)

        XCTAssertEqual(hidden.width, 200)
        XCTAssertEqual(hidden.height, 100)
        XCTAssertEqual(px.at(100, 50), [0, 0, 0])
        XCTAssertEqual(px.at(55, 30), [0, 0, 0], "inside the region")
        XCTAssertEqual(px.at(40, 50), [255, 0, 0], "left of the region")
        XCTAssertEqual(px.at(100, 10), [255, 0, 0], "above the region")
    }

    func testRegionsAreMeasuredFromTheTop() throws {
        let photo = try image(100, 100) { _, _ in (255, 0, 0) }

        let hidden = try XCTUnwrap(RedactImage.render(photo, regions: [CGRect(x: 0, y: 0, width: 1, height: 0.2)], settings: RedactSettings(style: .blackBox)))
        let px = try rgba(hidden)

        XCTAssertEqual(px.at(50, 5), [0, 0, 0], "the top rows are covered")
        XCTAssertEqual(px.at(50, 95), [255, 0, 0], "the bottom rows are not")
    }

    func testBlurSoftensTheRegionAndLeavesTheRestSharp() throws {
        let photo = try image(200, 200) { x, y in ((x / 4 + y / 4) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)) }

        let hidden = try XCTUnwrap(RedactImage.render(photo, regions: [middle], settings: RedactSettings(style: .blur, strength: 60)))
        let px = try rgba(hidden)

        XCTAssertTrue((60...195).contains(px.at(100, 100)[0]), "the centre should be a soft gray")
        XCTAssertEqual(px.at(5, 5), [255, 255, 255], "outside the region the squares stay sharp")
    }

    func testPixelateTurnsTheRegionIntoBlocks() throws {
        let photo = try image(200, 200) { x, y in ((x / 4 + y / 4) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)) }

        let hidden = try XCTUnwrap(RedactImage.render(photo, regions: [middle], settings: RedactSettings(style: .pixelate, strength: 60)))
        let px = try rgba(hidden)

        XCTAssertEqual(px.at(100, 100), px.at(101, 101), "inside a block every pixel matches")
        XCTAssertEqual(px.at(5, 5), [255, 255, 255])
    }

    func testNothingToCoverReturnsTheImageItself() throws {
        let photo = try image(20, 20) { _, _ in (1, 2, 3) }
        XCTAssertTrue(RedactImage.render(photo, regions: [], settings: RedactSettings()) === photo)
    }

    // MARK: Saving

    func testSavingKeepsTheOriginalTheFormatAndTheFullSize() throws {
        let source = dir.appendingPathComponent("shot.jpg")
        try write(try image(320, 200) { _, _ in (255, 0, 0) }, type: .jpeg, to: source)
        let before = try Data(contentsOf: source)

        let result = try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(style: .blackBox), into: out)

        XCTAssertEqual(result.regions, 1)
        XCTAssertEqual(result.url.lastPathComponent, "shot.jpg")
        let saved = try reader(result.url)
        XCTAssertEqual(CGImageSourceGetType(saved) as String?, UTType.jpeg.identifier)
        let props = CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 320)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 200)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original must not change")
    }

    func testCoveredPixelsAreGoneFromTheSavedFile() throws {
        let source = dir.appendingPathComponent("secret.png")
        try write(try image(100, 100) { x, _ in x < 50 ? (0, 255, 0) : (255, 0, 0) }, type: .png, to: source)

        let result = try RedactImage.save(source: source, regions: [CGRect(x: 0, y: 0, width: 1, height: 0.5)], settings: RedactSettings(style: .blackBox), into: out)

        let px = try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(try reader(result.url), 0, nil)))
        XCTAssertEqual(px.at(10, 10), [0, 0, 0])
        XCTAssertEqual(px.at(80, 10), [0, 0, 0])
        XCTAssertEqual(px.at(10, 90), [0, 255, 0], "below the region the picture is exact (PNG is lossless)")
    }

    func testSavedPictureIsUprightWhenTheOriginalIsRotatedByItsTag() throws {
        // Stored 80 wide and 40 high, tagged "rotate 90° clockwise" (orientation 6): the picture is 40 wide, 80 high.
        let source = dir.appendingPathComponent("rotated.jpg")
        try write(try image(80, 40) { _, _ in (0, 0, 255) }, type: .jpeg, to: source, properties: [kCGImagePropertyOrientation: 6])
        XCTAssertEqual(RedactImage.inspect(source), PixelSize(width: 40, height: 80))

        let result = try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(style: .blackBox), into: out)

        let props = CGImageSourceCopyPropertiesAtIndex(try reader(result.url), 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 80)
    }

    func testMetadataIsLeftOutOrKeptAsChosen() throws {
        let source = dir.appendingPathComponent("trip.jpg")
        let details: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam 1"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:28 12:00:00"],
        ]
        try write(try image(120, 80) { _, _ in (10, 20, 30) }, type: .jpeg, to: source, properties: details)
        XCTAssertEqual(MetadataStripper.scan(try reader(source)), [.location, .camera, .dates], "the test photo must carry the details")

        let clean = try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(removeMetadata: true), into: out)
        XCTAssertEqual(MetadataStripper.scan(try reader(clean.url)), [])

        let kept = try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(removeMetadata: false), into: out)
        XCTAssertTrue(MetadataStripper.scan(try reader(kept.url)).contains(.location))
        XCTAssertNotEqual(clean.url, kept.url, "a second copy gets its own name")
    }

    func testPictureWithoutAlphaStaysWithout() throws {
        let source = dir.appendingPathComponent("flat.png")
        try write(try image(60, 40) { _, _ in (9, 9, 9) }, type: .png, to: source)

        let result = try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(), into: out)

        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try reader(result.url), 0, nil))
        XCTAssertFalse(ImageConverter.hasAlpha(saved))
    }

    func testAnimatedImagesAreRefused() throws {
        let source = dir.appendingPathComponent("loop.gif")
        let frames = try [image(20, 20) { _, _ in (255, 0, 0) }, image(20, 20) { _, _ in (0, 0, 255) }]
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.gif.identifier as CFString, 2, nil))
        for frame in frames { CGImageDestinationAddImage(writer, frame, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(writer))

        XCTAssertNil(RedactImage.inspect(source))
        XCTAssertThrowsError(try RedactImage.save(source: source, regions: [middle], settings: RedactSettings(), into: out))
    }

    // MARK: Finding

    func testPlainPictureHasNoFacesOrText() throws {
        let source = dir.appendingPathComponent("wall.png")
        try write(try image(160, 120) { _, _ in (128, 128, 128) }, type: .png, to: source)

        XCTAssertEqual(try RedactImage.find(.faces, in: source), [])
        XCTAssertEqual(try RedactImage.find(.text, in: source), [])
    }

    func testFindTextReadsEveryLineAndSensitiveKeepsOnlyTheRightOnes() throws {
        let source = dir.appendingPathComponent("page.png")
        try write(try textPage(["Meeting notes for Monday", "Email jane.doe@example.com", "Thanks and see you there"]), type: .png, to: source)

        let lines = try RedactImage.find(.text, in: source)
        let sensitive = try RedactImage.find(.sensitive, in: source)

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(sensitive.count, 1)
        // The email is the middle of three lines, so its region sits in the middle third of the picture.
        let box = try XCTUnwrap(sensitive.first)
        XCTAssertTrue((0.3...0.7).contains(box.midY), "found at \(box)")
        XCTAssertTrue(lines.allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0) })
    }

    // MARK: Helpers

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 1e-9, file: file, line: line)
    }

    /// White page with black text, one line under the other, large enough for reliable recognition.
    private func textPage(_ lines: [String]) throws -> CGImage {
        let (w, h) = (1200, 600)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: attributes).draw(at: CGPoint(x: 60, y: CGFloat(h) - 160 - CGFloat(i) * 190))
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(context.makeImage())
    }

    private func image(_ w: Int, _ h: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = color(x, y)
                let i = (y * w + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        return try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let made = context.makeImage() else { throw CocoaError(.fileReadUnknown) }
            return made
        }
    }

    private func write(_ image: CGImage, type: UTType, to url: URL, properties: [CFString: Any] = [:]) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func reader(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadUnknown) }
        return source
    }

    /// The pixels as RGBA bytes, row 0 at the top.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        func at(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * width + x) * 4
            return Array(bytes[i..<(i + 3)])
        }
    }

    private func rgba(_ image: CGImage) throws -> Pixels {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw CocoaError(.fileReadUnknown)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(bytes: bytes, width: w)
    }
}
