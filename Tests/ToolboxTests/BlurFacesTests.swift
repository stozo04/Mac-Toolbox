import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class BlurFacesTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("blur-faces-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // A 200 x 200 red photo with one face box in the middle (the box covers half of each side).
    private let face = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

    // MARK: Saving

    func testPhotoWithNoFacesToHideIsCopiedByteForByte() throws {
        let source = dir.appendingPathComponent("plain.png")
        try write(try image(64, 48) { _, _ in (10, 200, 30) }, type: .png, to: source)

        let result = try FaceBlur.save(source: source, faces: [], settings: FaceBlurSettings(), into: out)

        XCTAssertEqual(result.facesHidden, 0)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
        XCTAssertEqual(result.url.lastPathComponent, "plain.png")
    }

    func testSavingKeepsTheOriginalAndTheFormat() throws {
        let source = dir.appendingPathComponent("portrait.jpg")
        try write(try image(80, 60) { _, _ in (255, 0, 0) }, type: .jpeg, to: source)
        let before = try Data(contentsOf: source)

        let result = try FaceBlur.save(source: source, faces: [face], settings: FaceBlurSettings(style: .blackBox), into: out)

        XCTAssertEqual(result.facesHidden, 1)
        XCTAssertEqual(result.url.pathExtension, "jpg")
        XCTAssertEqual(CGImageSourceGetType(try reader(result.url)) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original must not change")
    }

    func testOutputIsUprightWhenTheOriginalIsRotatedByItsTag() throws {
        // Stored 80 wide and 40 high, but tagged "rotate 90° clockwise" (orientation 6): the photo is 40 wide, 80 high.
        let source = dir.appendingPathComponent("rotated.jpg")
        try write(try image(80, 40) { _, _ in (0, 0, 255) }, type: .jpeg, to: source, orientation: 6)

        let result = try FaceBlur.save(source: source, faces: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)],
                                       settings: FaceBlurSettings(style: .blackBox), into: out)

        let saved = try reader(result.url)
        let props = CGImageSourceCopyPropertiesAtIndex(saved, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 40)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 80)
    }

    // MARK: Hiding

    func testBlackBoxCoversTheFaceAndItsMarginOnly() throws {
        let photo = try image(200, 200) { _, _ in (255, 0, 0) }

        let hidden = try XCTUnwrap(FaceBlur.render(photo, faces: [face], settings: FaceBlurSettings(style: .blackBox)))
        let px = try rgba(hidden)

        XCTAssertEqual(px.at(100, 100), [0, 0, 0])
        XCTAssertEqual(px.at(40, 100), [0, 0, 0], "the margin is covered too")
        XCTAssertEqual(px.at(20, 100), [255, 0, 0], "pixels outside the margin stay as they were")
        XCTAssertEqual(px.at(5, 5), [255, 0, 0])
    }

    func testBlurSoftensTheFaceAndLeavesTheRestSharp() throws {
        // Black and white squares of 4 px: sharp everywhere, so any blur shows up as gray.
        let photo = try image(200, 200) { x, y in ((x / 4 + y / 4) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)) }

        let hidden = try XCTUnwrap(FaceBlur.render(photo, faces: [face], settings: FaceBlurSettings(style: .blur, strength: 60)))
        let px = try rgba(hidden)

        XCTAssertTrue((60...195).contains(px.at(100, 100)[0]), "the centre should be a soft gray")
        XCTAssertEqual(px.at(5, 5), [255, 255, 255], "outside the face the squares stay sharp")
    }

    func testPixelateTurnsTheFaceIntoBlocks() throws {
        let photo = try image(200, 200) { x, y in ((x / 4 + y / 4) % 2 == 0 ? (255, 255, 255) : (0, 0, 0)) }

        let hidden = try XCTUnwrap(FaceBlur.render(photo, faces: [face], settings: FaceBlurSettings(style: .pixelate, strength: 60)))
        let px = try rgba(hidden)

        // Inside a block every pixel matches; the 4 px squares are gone from the face.
        XCTAssertEqual(px.at(100, 100), px.at(101, 101))
        XCTAssertEqual(px.at(5, 5), [255, 255, 255])
    }

    // MARK: Finding

    func testPlainPhotoHasNoFaces() throws {
        let source = dir.appendingPathComponent("wall.png")
        try write(try image(120, 90) { _, _ in (128, 128, 128) }, type: .png, to: source)

        XCTAssertEqual(try FaceBlur.detectFaces(in: source), [])
    }

    // MARK: Helpers

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

    private func write(_ image: CGImage, type: UTType, to url: URL, orientation: Int? = nil) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0] } ?? [:]
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
