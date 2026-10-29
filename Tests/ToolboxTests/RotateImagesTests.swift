import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class RotateImagesTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("rotate-images-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Settings

    func testFourTurnsInEitherDirectionComeBackToNoChange() {
        var s = RotateSettings()
        XCTAssertTrue(s.isIdentity)
        XCTAssertEqual(s.summary, "No change")
        for _ in 0..<4 { s.rotateRight() }
        XCTAssertTrue(s.isIdentity)
        for _ in 0..<4 { s.rotateLeft() }
        XCTAssertTrue(s.isIdentity)
    }

    func testFlippingTwiceComesBackToNoChange() {
        var s = RotateSettings()
        s.flipHorizontal(); s.flipHorizontal()
        XCTAssertTrue(s.isIdentity)
        s.flipVertical(); s.flipVertical()
        XCTAssertTrue(s.isIdentity)
        s.rotateRight(); s.flipHorizontal(); s.flipHorizontal(); s.rotateLeft()
        XCTAssertTrue(s.isIdentity)
    }

    func testRotateLeftThenRightCancels() {
        var s = RotateSettings()
        s.flipVertical()
        let flipped = s
        s.rotateLeft(); s.rotateRight()
        XCTAssertEqual(s, flipped)
    }

    func testOnlySidewaysTurnsSwapWidthAndHeight() {
        var s = RotateSettings()
        let size = PixelSize(width: 400, height: 300)
        XCTAssertEqual(s.output(for: size), size)
        s.rotateRight()
        XCTAssertEqual(s.output(for: size), PixelSize(width: 300, height: 400))
        s.rotateRight()
        XCTAssertEqual(s.output(for: size), size)
        s.flipHorizontal()
        XCTAssertEqual(s.output(for: size), size)
        s.rotateLeft()
        XCTAssertEqual(s.output(for: size), PixelSize(width: 300, height: 400))
    }

    func testEveryCombinationHasItsOwnOrientationAndLabel() {
        var seen = Set<Int>(), labels = Set<String>()
        for mirrored in [false, true] {
            for turns in 0..<4 {
                var s = RotateSettings()
                if mirrored { s.flipHorizontal() }
                for _ in 0..<turns { s.rotateRight() }
                seen.insert(s.orientation)
                labels.insert(s.summary)
            }
        }
        XCTAssertEqual(seen, Set(1...8))
        XCTAssertEqual(labels.count, 8)
    }

    // MARK: Pixels (the picture has a different color in each corner)

    func testRotateRightMovesTheBottomLeftCornerToTheTopLeft() throws {
        var s = RotateSettings(); s.rotateRight()
        XCTAssertEqual(try corners(after: s), [.blue, .red, .yellow, .green])
    }

    func testRotateLeftMovesTheTopRightCornerToTheTopLeft() throws {
        var s = RotateSettings(); s.rotateLeft()
        XCTAssertEqual(try corners(after: s), [.green, .yellow, .red, .blue])
    }

    func testTwoTurnsReverseTheWholePicture() throws {
        var s = RotateSettings(); s.rotateRight(); s.rotateRight()
        XCTAssertEqual(try corners(after: s), [.yellow, .blue, .green, .red])
    }

    func testFlipHorizontalMirrorsLeftToRight() throws {
        var s = RotateSettings(); s.flipHorizontal()
        XCTAssertEqual(try corners(after: s), [.green, .red, .yellow, .blue])
    }

    func testFlipVerticalMirrorsTopToBottom() throws {
        var s = RotateSettings(); s.flipVertical()
        XCTAssertEqual(try corners(after: s), [.blue, .yellow, .red, .green])
    }

    /// Each button acts on the picture as it looks at that moment: turn it right, then mirror what is on screen.
    func testButtonsActOnWhatYouSee() throws {
        var s = RotateSettings(); s.rotateRight(); s.flipHorizontal()
        // After turning right the corners read blue, red / yellow, green; mirrored left to right: red, blue / green, yellow.
        XCTAssertEqual(try corners(after: s), [.red, .blue, .green, .yellow])

        var t = RotateSettings(); t.rotateRight(); t.flipVertical()
        XCTAssertEqual(try corners(after: t), [.yellow, .green, .blue, .red])

        var u = RotateSettings(); u.flipHorizontal(); u.rotateLeft()
        // Mirrored: green, red / yellow, blue; turned left: red, blue / green, yellow.
        XCTAssertEqual(try corners(after: u), [.red, .blue, .green, .yellow])
    }

    func testTurnedPictureHasTurnedSize() throws {
        var s = RotateSettings(); s.rotateRight()
        let turned = try ImageRotator.apply(s, to: try quadrants(width: 8, height: 4))
        XCTAssertEqual(turned.width, 4)
        XCTAssertEqual(turned.height, 8)
    }

    // MARK: Files

    func testJPEGIsSavedTurnedAndStaysAJPEG() throws {
        let source = try makeFile("photo.jpg", type: .jpeg)
        var s = RotateSettings(); s.rotateRight()
        let result = try ImageRotator.rotate(source: source, settings: s, into: out)

        XCTAssertEqual(result.from, PixelSize(width: 400, height: 300))
        XCTAssertEqual(result.to, PixelSize(width: 300, height: 400))
        XCTAssertEqual(ImageResizer.pixelSize(of: result.url), PixelSize(width: 300, height: 400))
        XCTAssertEqual(result.url.deletingLastPathComponent().standardizedFileURL, out.standardizedFileURL)
        XCTAssertEqual(result.url.pathExtension, "jpg")
        XCTAssertEqual(try typeOf(result.url), UTType.jpeg.identifier)
        XCTAssertEqual(result.bytes, size(result.url))
        XCTAssertEqual(result.sourceBytes, size(source))
    }

    func testPNGKeepsItsPixelsExactlyAndMatchesThePreview() throws {
        let source = try makeFile("shot.png", type: .png)
        var s = RotateSettings(); s.rotateLeft(); s.flipHorizontal()
        let result = try ImageRotator.rotate(source: source, settings: s, into: out)

        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil)), 0, nil))
        let expected = try ImageRotator.apply(s, to: try quadrants(width: 400, height: 300))
        XCTAssertEqual(try corners(of: saved), try corners(of: expected))
        XCTAssertEqual(try typeOf(result.url), UTType.png.identifier)
    }

    func testAPhotoStoredSidewaysIsTurnedFromHowItLooks() throws {
        // Stored 400 × 300 with a "turn right" tag: it looks 300 × 400. Turning it right again makes it 400 × 300 upside down.
        let source = try makeFile("tagged.jpg", type: .jpeg, orientation: 6)
        var s = RotateSettings(); s.rotateRight()
        let result = try ImageRotator.rotate(source: source, settings: s, into: out)

        XCTAssertEqual(result.from, PixelSize(width: 300, height: 400))
        XCTAssertEqual(result.to, PixelSize(width: 400, height: 300))
        XCTAssertEqual(ImageResizer.pixelSize(of: result.url), PixelSize(width: 400, height: 300))
    }

    func testCameraDetailsSurvive() throws {
        let source = try makeFile("cam.jpg", type: .jpeg, make: "TestCam")
        var s = RotateSettings(); s.flipVertical()
        let result = try ImageRotator.rotate(source: source, settings: s, into: out)

        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil)), 0, nil) as? [CFString: Any])
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "TestCam")
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }

    func testHEICIsSavedAsHEIC() throws {
        let source = try makeFile("photo.heic", type: .heic)
        var s = RotateSettings(); s.rotateRight()
        let result = try ImageRotator.rotate(source: source, settings: s, into: out)
        XCTAssertEqual(try typeOf(result.url), UTType.heic.identifier)
        XCTAssertEqual(result.to, PixelSize(width: 300, height: 400))
    }

    func testWebPIsSavedAsWebP() throws {
        let source = try makeFile("photo.png", type: .png)
        let webp = try ImageConverter.convert(source: source, settings: ConvertSettings(format: .webp, quality: 90), into: dir).url
        var s = RotateSettings(); s.flipHorizontal(); s.rotateRight()
        let result = try ImageRotator.rotate(source: webp, settings: s, into: out)
        XCTAssertEqual(result.url.pathExtension, "webp")
        XCTAssertEqual(ImageResizer.pixelSize(of: result.url), PixelSize(width: 300, height: 400))
    }

    func testOriginalsAreNeverTouched() throws {
        let source = try makeFile("keep.png", type: .png)
        let before = try Data(contentsOf: source)
        var s = RotateSettings(); s.rotateRight()
        _ = try ImageRotator.rotate(source: source, settings: s, into: out)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testSameNameTwiceDoesNotOverwrite() throws {
        let source = try makeFile("same.png", type: .png)
        var s = RotateSettings(); s.rotateRight()
        let a = try ImageRotator.rotate(source: source, settings: s, into: out)
        let b = try ImageRotator.rotate(source: source, settings: s, into: out)
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
    }

    func testNoChangeSavesNothing() throws {
        let source = try makeFile("none.png", type: .png)
        XCTAssertThrowsError(try ImageRotator.rotate(source: source, settings: RotateSettings(), into: out)) {
            XCTAssertTrue($0 is RotateError)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    func testAFileThatIsNotAnImageFails() throws {
        let text = dir.appendingPathComponent("notes.png")
        try Data("hello".utf8).write(to: text)
        var s = RotateSettings(); s.rotateRight()
        XCTAssertThrowsError(try ImageRotator.rotate(source: text, settings: s, into: out))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    // MARK: Helpers

    private enum Color { case red, green, blue, yellow }

    private func rgb(_ c: Color) -> (UInt8, UInt8, UInt8) {
        switch c {
        case .red: (230, 30, 30)
        case .green: (30, 200, 30)
        case .blue: (30, 30, 230)
        case .yellow: (240, 220, 20)
        }
    }

    /// Red top left, green top right, blue bottom left, yellow bottom right.
    private func quadrants(width w: Int, height h: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c: Color = y < h / 2 ? (x < w / 2 ? .red : .green) : (x < w / 2 ? .blue : .yellow)
                let (r, g, b) = rgb(c)
                let i = (y * w + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
            }
        }
        return try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
    }

    /// The colors at the middle of the four quarters: top left, top right, bottom left, bottom right.
    private func corners(of image: CGImage) throws -> [Color] {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        func color(_ x: Int, _ y: Int) throws -> Color {
            let i = (y * w + x) * 4
            let p = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
            let all: [Color] = [.red, .green, .blue, .yellow]
            let best = all.min { distance(p, rgb($0)) < distance(p, rgb($1)) }
            return try XCTUnwrap(best)
        }
        return [try color(w / 4, h / 4), try color(3 * w / 4, h / 4), try color(w / 4, 3 * h / 4), try color(3 * w / 4, 3 * h / 4)]
    }

    private func distance(_ a: (Int, Int, Int), _ b: (UInt8, UInt8, UInt8)) -> Int {
        abs(a.0 - Int(b.0)) + abs(a.1 - Int(b.1)) + abs(a.2 - Int(b.2))
    }

    private func corners(after settings: RotateSettings) throws -> [Color] {
        try corners(of: try ImageRotator.apply(settings, to: try quadrants(width: 8, height: 6)))
    }

    private func makeFile(_ name: String, type: UTType, orientation: Int = 1, make: String? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let image = try quadrants(width: 400, height: 300)
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if orientation != 1 { properties[kCGImagePropertyOrientation] = orientation }
        if let make { properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: make] }
        CGImageDestinationAddImage(writer, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func typeOf(_ url: URL) throws -> String {
        try XCTUnwrap(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))) as String?)
    }

    private func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
