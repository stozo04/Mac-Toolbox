import CoreGraphics
import CoreImage
import XCTest
@testable import Toolbox

final class RemoveBackgroundTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remove-background-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // A 40 x 20 red photo. The masks below keep its left half and drop the right half.
    private func red() throws -> CGImage { try solid(40, 20, (255, 0, 0)) }

    // MARK: Compositing

    func testTransparentBackgroundKeepsOnlyTheSubject() throws {
        let cut = try XCTUnwrap(RemoveBackground.compose(red(), mask: mask(40, 20, white: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                                         settings: RemoveBackgroundSettings(background: .transparent)))

        let pixels = try rgba(cut)
        XCTAssertEqual(try pixels.rgba(5, 10), [255, 0, 0, 255], "subject keeps its color and is opaque")
        XCTAssertEqual(try pixels.rgba(30, 10).element(at: 3), 0, "background is transparent")
    }

    func testWhiteBackgroundFillsTheRest() throws {
        let cut = try XCTUnwrap(RemoveBackground.compose(red(), mask: mask(40, 20, white: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                                         settings: RemoveBackgroundSettings(background: .white)))

        let pixels = try rgba(cut)
        XCTAssertEqual(try pixels.rgba(5, 10), [255, 0, 0, 255])
        XCTAssertEqual(try pixels.rgba(30, 10), [255, 255, 255, 255])
    }

    func testColorBackgroundFillsTheRest() throws {
        let settings = RemoveBackgroundSettings(background: .custom, customColor: RGBColor(red: 0, green: 0, blue: 1))
        let cut = try XCTUnwrap(RemoveBackground.compose(red(), mask: mask(40, 20, white: CGRect(x: 0, y: 0, width: 20, height: 20)),
                                                         settings: settings))

        XCTAssertEqual(try rgba(cut).rgba(30, 10), [0, 0, 255, 255])
    }

    // MARK: Cropping

    func testSubjectBoundsAreMeasuredFromTheTopLeft() throws {
        // White 10 x 6 block whose bottom edge is 2 pixels above the bottom of a 40 x 20 mask: from the top it starts at y 12.
        let bounds = try XCTUnwrap(RemoveBackground.subjectBounds(of: mask(40, 20, white: CGRect(x: 4, y: 2, width: 10, height: 6))))

        XCTAssertEqual(bounds, CGRect(x: 4, y: 12, width: 10, height: 6))
    }

    func testCropToSubjectTrimsTheCutout() throws {
        let m = try mask(40, 20, white: CGRect(x: 4, y: 2, width: 10, height: 6))
        let cut = try XCTUnwrap(RemoveBackground.compose(red(), mask: m, settings: RemoveBackgroundSettings()))
        let bounds = try XCTUnwrap(RemoveBackground.subjectBounds(of: m))

        let cropped = try XCTUnwrap(cut.cropping(to: bounds))
        XCTAssertEqual(cropped.width, 10)
        XCTAssertEqual(cropped.height, 6)
    }

    func testMaskWithNoSubjectHasNoBounds() throws {
        XCTAssertNil(RemoveBackground.subjectBounds(of: try mask(40, 20, white: .zero)))
    }

    // MARK: Saving

    func testUnreadableFileIsRefused() throws {
        let source = dir.appendingPathComponent("notes.txt")
        try "not an image".write(to: source, atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        XCTAssertThrowsError(try RemoveBackground.save(source: source, settings: RemoveBackgroundSettings(), into: out)) { error in
            XCTAssertEqual(error as? RemoveBackgroundError, .unreadable)
        }
    }

    // MARK: Helpers

    private func solid(_ w: Int, _ h: Int, _ color: (UInt8, UInt8, UInt8)) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(context.makeImage())
    }

    /// A grayscale mask: white inside `white`, black elsewhere, in the same orientation as the photo.
    private func mask(_ w: Int, _ h: Int, white: CGRect) throws -> CIImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(white)
        return CIImage(cgImage: try XCTUnwrap(context.makeImage()))
    }

    private func rgba(_ image: CGImage) throws -> RGBAPixels { try RGBAPixels(image, alpha: .premultipliedLast) }
}
