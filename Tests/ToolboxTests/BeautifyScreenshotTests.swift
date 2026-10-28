import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class BeautifyScreenshotTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("beautify-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Canvas

    func testWideFrameGrowsHeightForTheRatio() {
        let (w, h) = BeautifyScreenshot.canvasSize(2000, 500, aspect: 1)
        XCTAssertEqual(w, 2000)
        XCTAssertEqual(h, 2000)
    }

    func testTallFrameGrowsWidthForTheRatio() {
        let (w, h) = BeautifyScreenshot.canvasSize(500, 2000, aspect: 16.0 / 9.0)
        XCTAssertEqual(w, 2000 * 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(h, 2000)
    }

    func testFrameThatFitsTheRatioIsOnlyGrownOnOneSide() {
        let (w, h) = BeautifyScreenshot.canvasSize(1000, 1000, aspect: 4.0 / 5.0)
        XCTAssertEqual(w, 1000)
        XCTAssertEqual(h, 1250)
    }

    func testAutoFollowsTheFramedScreenshot() {
        let (w, h) = BeautifyScreenshot.canvasSize(220, 120, aspect: nil)
        XCTAssertEqual([w, h], [220, 120])
    }

    // MARK: Framing

    func testAutoFrameIsTheScreenshotPlusPadding() throws {
        // Shorter side 100 px; padding 0.4 on the S-to-L scale is 10% of it, so 10 px on each side.
        let shot = try image(200, 100) { _, _ in (255, 0, 0) }
        let framed = try XCTUnwrap(BeautifyScreenshot.frame(shot, settings: BeautifySettings(), background: nil))
        XCTAssertEqual([framed.width, framed.height], [220, 120])
    }

    func testScreenshotPixelsAreKeptAndBackgroundSurrounds() throws {
        var settings = BeautifySettings()
        settings.cornerRadius = 0
        settings.shadow = .none
        let shot = try image(200, 100) { _, _ in (255, 0, 0) }
        let px = try rgba(try XCTUnwrap(BeautifyScreenshot.frame(shot, settings: settings, background: nil)))

        XCTAssertEqual(px.at(110, 60), [255, 0, 0], "the screenshot is drawn as it is, unscaled")
        XCTAssertNotEqual(px.at(2, 2), [255, 0, 0], "the padding shows the background")
        XCTAssertEqual(px.alpha(2, 2), 255, "the built-in gradients are opaque")
    }

    func testTransparentBackgroundLeavesThePaddingSeeThrough() throws {
        var settings = BeautifySettings()
        settings.background = .transparent
        settings.shadow = .none
        let shot = try image(200, 100) { _, _ in (255, 0, 0) }
        let px = try rgba(try XCTUnwrap(BeautifyScreenshot.frame(shot, settings: settings, background: nil)))

        XCTAssertEqual(px.alpha(2, 2), 0)
        XCTAssertEqual(px.alpha(110, 60), 255)
    }

    func testCustomColorFillsThePadding() throws {
        var settings = BeautifySettings()
        settings.background = .custom
        settings.customColor = RGBColor(red: 0, green: 0, blue: 1)
        settings.shadow = .none
        let shot = try image(200, 100) { _, _ in (255, 0, 0) }
        let px = try rgba(try XCTUnwrap(BeautifyScreenshot.frame(shot, settings: settings, background: nil)))

        XCTAssertEqual(px.at(2, 2), [0, 0, 255])
    }

    func testSixteenByNineRatioIsHonoured() throws {
        var settings = BeautifySettings()
        settings.ratio = .widescreen
        let shot = try image(200, 100) { _, _ in (255, 0, 0) }
        let framed = try XCTUnwrap(BeautifyScreenshot.frame(shot, settings: settings, background: nil))
        XCTAssertEqual(Double(framed.width) / Double(framed.height), 16.0 / 9.0, accuracy: 0.02)
    }

    // MARK: Saving

    func testSaveWritesAFramedPNGAndKeepsTheOriginal() throws {
        let source = dir.appendingPathComponent("shot.png")
        try write(try image(200, 100) { _, _ in (255, 0, 0) }, to: source)
        let before = try Data(contentsOf: source)

        let result = try BeautifyScreenshot.save(source: source, settings: BeautifySettings(), into: out)

        XCTAssertEqual(result.url.lastPathComponent, "shot.png")
        XCTAssertEqual([result.width, result.height], [220, 120])
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(reader) as String?, UTType.png.identifier)
        XCTAssertEqual(try Data(contentsOf: source), before, "the original must not change")
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
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let made = context.makeImage() else { throw CocoaError(.fileReadUnknown) }
            return made
        }
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The pixels as premultiplied RGBA bytes, row 0 at the top, read with alpha kept.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int

        func at(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * width + x) * 4
            return Array(bytes[i..<(i + 3)])
        }

        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
    }

    private func rgba(_ image: CGImage) throws -> Pixels {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw CocoaError(.fileReadUnknown)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(bytes: bytes, width: w)
    }
}
