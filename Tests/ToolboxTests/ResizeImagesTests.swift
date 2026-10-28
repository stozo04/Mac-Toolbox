import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class ResizeImagesTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("resize-images-\(UUID())")
        out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Plan

    private func plan(_ w: Int, _ h: Int, _ settings: ImageResizeSettings) -> PixelSize {
        ImageResizePlan.output(for: PixelSize(width: w, height: h), settings: settings)
    }

    func testPercentageScalesBothSides() {
        XCTAssertEqual(plan(4000, 3000, ImageResizeSettings(mode: .percentage, percent: 50)), PixelSize(width: 2000, height: 1500))
        XCTAssertEqual(plan(4000, 3000, ImageResizeSettings(mode: .percentage, percent: 200)), PixelSize(width: 8000, height: 6000))
    }

    func testLongestSideWorksForLandscapeAndPortrait() {
        let s = ImageResizeSettings(mode: .longestSide, longestSide: 1920)
        XCTAssertEqual(plan(4000, 3000, s), PixelSize(width: 1920, height: 1440))
        XCTAssertEqual(plan(3000, 4000, s), PixelSize(width: 1440, height: 1920))
    }

    func testSmallImagesStayUnlessEnlargeIsOn() {
        var s = ImageResizeSettings(mode: .longestSide, longestSide: 1920)
        XCTAssertEqual(plan(800, 600, s), PixelSize(width: 800, height: 600))
        s.enlarge = true
        XCTAssertEqual(plan(800, 600, s), PixelSize(width: 1920, height: 1440))
    }

    func testSizeKeepingProportionsFitsInsideTheBox() {
        let s = ImageResizeSettings(mode: .size, width: 1080, height: 1080, keepProportions: true)
        XCTAssertEqual(plan(4000, 2000, s), PixelSize(width: 1080, height: 540))
        XCTAssertEqual(plan(2000, 4000, s), PixelSize(width: 540, height: 1080))
    }

    func testSizeWithoutProportionsStretchesToTheExactSize() {
        var s = ImageResizeSettings(mode: .size, width: 1080, height: 1080, keepProportions: false)
        XCTAssertEqual(plan(4000, 2000, s), PixelSize(width: 1080, height: 1080))
        // A side never grows without Enlarge.
        XCTAssertEqual(plan(800, 2000, s), PixelSize(width: 800, height: 1080))
        s.enlarge = true
        XCTAssertEqual(plan(800, 2000, s), PixelSize(width: 1080, height: 1080))
    }

    // MARK: Saving

    func testResizesAJPEGToTheLongestSideAndKeepsItAJPEG() throws {
        let source = try makeImage(.jpeg, name: "photo", width: 400, height: 300)
        let result = try ImageResizer.resize(source: source, settings: ImageResizeSettings(mode: .longestSide, longestSide: 200), into: out)

        XCTAssertEqual(result.outcome, .resized)
        XCTAssertEqual(result.to, PixelSize(width: 200, height: 150))
        XCTAssertEqual(try dimensions(result.url), PixelSize(width: 200, height: 150))
        XCTAssertEqual(try typeOf(result.url), UTType.jpeg.identifier)
        XCTAssertEqual(result.url.pathExtension, "jpg")
    }

    func testOriginalIsLeftAlone() throws {
        let source = try makeImage(.png, name: "shot", width: 400, height: 300)
        let before = try Data(contentsOf: source)
        _ = try ImageResizer.resize(source: source, settings: ImageResizeSettings(mode: .percentage, percent: 25), into: out)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testPNGKeepsItsTransparency() throws {
        let source = try makeImage(.png, name: "logo", width: 100, height: 100, transparent: true)
        let result = try ImageResizer.resize(source: source, settings: ImageResizeSettings(mode: .percentage, percent: 50), into: out)
        XCTAssertEqual(try dimensions(result.url), PixelSize(width: 50, height: 50))
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertTrue(ImageConverter.hasAlpha(image))
    }

    func testImageAlreadyAtTheTargetIsCopiedUnchanged() throws {
        let source = try makeImage(.jpeg, name: "photo", width: 400, height: 300)
        let result = try ImageResizer.resize(source: source, settings: ImageResizeSettings(mode: .longestSide, longestSide: 1920), into: out)

        XCTAssertEqual(result.outcome, .unchanged)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
    }

    func testTwoPhotosWithTheSameNameDoNotOverwriteEachOther() throws {
        let a = try makeImage(.png, name: "same", width: 40, height: 30, in: dir.appendingPathComponent("a"))
        let b = try makeImage(.png, name: "same", width: 40, height: 30, in: dir.appendingPathComponent("b"))
        let s = ImageResizeSettings(mode: .percentage, percent: 50)
        let first = try ImageResizer.resize(source: a, settings: s, into: out)
        let second = try ImageResizer.resize(source: b, settings: s, into: out)
        XCTAssertNotEqual(first.url, second.url)
    }

    func testPixelSizeTurnsRotatedPhotosUpright() throws {
        let source = try makeImage(.jpeg, name: "turned", width: 400, height: 300, orientation: 6)
        XCTAssertEqual(ImageResizer.pixelSize(of: source), PixelSize(width: 300, height: 400))
        let result = try ImageResizer.resize(source: source, settings: ImageResizeSettings(mode: .longestSide, longestSide: 200), into: out)
        XCTAssertEqual(try dimensions(result.url), PixelSize(width: 150, height: 200))
    }

    func testNonImageFailsCleanly() throws {
        let url = dir.appendingPathComponent("note.png")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageResizer.resize(source: url, settings: ImageResizeSettings(), into: out))
    }

    // MARK: Dragging

    @MainActor private func modelWithPhoto(_ settings: ImageResizeSettings) throws -> ResizeImagesModel {
        let model = ResizeImagesModel()
        model.add([try makeImage(.jpeg, name: "photo", width: 400, height: 300)])
        model.settings = settings
        return model
    }

    @MainActor func testDraggingASideSetsTheLongestSideAndTurnsEnlargeOn() throws {
        let model = try modelWithPhoto(ImageResizeSettings(mode: .longestSide, longestSide: 200))
        model.drag(.right, width: 800, height: 300)
        XCTAssertEqual(model.settings.longestSide, 800)
        XCTAssertTrue(model.settings.enlarge)
    }

    @MainActor func testDraggingShrinksWithoutTurningEnlargeOn() throws {
        let model = try modelWithPhoto(ImageResizeSettings(mode: .percentage, percent: 100))
        model.drag(.bottomRight, width: 100, height: 75)
        XCTAssertEqual(model.settings.percent, 25)
        XCTAssertFalse(model.settings.enlarge)
    }

    @MainActor func testDraggingACornerKeepsTheShapeWhenProportionsAreKept() throws {
        let model = try modelWithPhoto(ImageResizeSettings(mode: .size, width: 400, height: 300, keepProportions: true))
        model.drag(.bottomRight, width: 200, height: 400)  // leans tall: the diagonal decides
        let (w, h) = (model.settings.width, model.settings.height)
        XCTAssertEqual(Double(w) / Double(h), 4.0 / 3.0, accuracy: 0.02)
    }

    @MainActor func testDraggingASideStretchesOnlyThatSideWhenProportionsAreOff() throws {
        let model = try modelWithPhoto(ImageResizeSettings(mode: .size, width: 400, height: 300, keepProportions: false))
        model.drag(.right, width: 250, height: 300)
        XCTAssertEqual(model.settings.width, 250)
        XCTAssertEqual(model.settings.height, 300)
        model.drag(.top, width: 250, height: 120)
        XCTAssertEqual(model.settings.height, 120)
    }

    @MainActor func testTypingAWidthFollowsTheHeightOnlyWhenProportionsAreKept() throws {
        let model = try modelWithPhoto(ImageResizeSettings(mode: .size, keepProportions: true))
        model.setWidth(200)
        XCTAssertEqual(model.settings.height, 150)
        model.setKeepProportions(false)
        model.setWidth(300)
        XCTAssertEqual(model.settings.height, 150)
    }

    // MARK: Helpers

    private func makeImage(_ type: UTType, name: String, width: Int, height: Int, transparent: Bool = false,
                           orientation: Int = 1, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? dir!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = type == .jpeg ? "jpg" : "png"
        let url = folder.appendingPathComponent("\(name).\(ext)")
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: (transparent ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        for i in 0..<10 {
            context.setFillColor(CGColor(red: Double(i) / 10, green: 0.4, blue: 1 - Double(i) / 10, alpha: transparent && i % 2 == 0 ? 0 : 1))
            context.fill(CGRect(x: i * width / 10, y: 0, width: width / 10, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return url
    }

    private func dimensions(_ url: URL) throws -> PixelSize {
        try XCTUnwrap(ImageResizer.pixelSize(of: url))
    }

    private func typeOf(_ url: URL) throws -> String {
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceGetType(reader)) as String
    }
}
