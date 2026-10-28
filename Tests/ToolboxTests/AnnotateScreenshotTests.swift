import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import Toolbox

final class AnnotateScreenshotTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("annotate-screenshot-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Helpers

    /// A picture with a `top` color in its upper half and a `bottom` color in the lower half.
    private func picture(width: Int = 200, height: Int = 100, top: (UInt8, UInt8, UInt8) = (255, 255, 255), bottom: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext's origin is the bottom left, so the "top" half is the upper rows of the finished picture.
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bottom.0) / 255, green: CGFloat(bottom.1) / 255, blue: CGFloat(bottom.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        ctx.setFillColor(CGColor(srgbRed: CGFloat(top.0) / 255, green: CGFloat(top.1) / 255, blue: CGFloat(top.2) / 255, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return ctx.makeImage()!
    }

    /// A picture whose left half is black and right half white.
    private func splitPicture(width: Int = 200, height: Int = 100) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        return ctx.makeImage()!
    }

    /// RGBA of the pixel at (x, y), counted from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let data = image.dataProvider!.data! as Data
        let i = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }

    private func mark(_ kind: AnnotationTool, from a: CGPoint, to b: CGPoint, _ edit: (inout AnnotationStyle) -> Void = { _ in }) -> Annotation {
        var style = AnnotationStyle()
        style.shadow = false
        edit(&style)
        return Annotation(kind: kind, start: a, end: b, style: style)
    }

    private func render(_ image: CGImage, _ marks: [Annotation]) -> CGImage {
        AnnotateRenderer.render(image: image, annotations: marks, blurs: AnnotateBlurCache())!
    }

    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: Tools

    func testEveryToolHasItsOwnKey() {
        let keys = AnnotationTool.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(AnnotationTool(key: "A"), .arrow)
        XCTAssertEqual(AnnotationTool(key: "r"), .rectangle)
        XCTAssertEqual(AnnotationTool(key: "t"), .text)
        XCTAssertEqual(AnnotationTool(key: "n"), .step)
        XCTAssertEqual(AnnotationTool(key: "b"), .blur)
        XCTAssertNil(AnnotationTool(key: "z"))
    }

    // MARK: Geometry

    func testShiftSnapsLinesToFortyFiveDegreesAndBoxesToSquares() {
        let snapped = AnnotateGeometry.constrained(CGPoint(x: 100, y: 20), from: .zero, for: .arrow)
        XCTAssertEqual(snapped.x, hypot(100, 20), accuracy: 1e-6, "a shallow line becomes horizontal and keeps its length")
        XCTAssertEqual(snapped.y, 0, accuracy: 1e-6)
        let diagonal = AnnotateGeometry.constrained(CGPoint(x: 60, y: 50), from: .zero, for: .line)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 1e-6)
        let square = AnnotateGeometry.constrained(CGPoint(x: -30, y: 80), from: CGPoint(x: 10, y: 10), for: .rectangle)
        XCTAssertEqual(square, CGPoint(x: -60, y: 80), "the longer side (70) wins, in the direction dragged")
    }

    func testArrowHeadEndsAtTheTipAndLeavesRoomForTheShaft() {
        let shape = AnnotateGeometry.arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), lineWidth: 3, unit: 1)
        XCTAssertEqual(shape.head[0], CGPoint(x: 100, y: 0))
        XCTAssertLessThan(shape.shaftEnd.x, 100)
        XCTAssertEqual(shape.head[1].y, -shape.head[3].y, accuracy: 1e-9, "the wings sit either side of the line")
        let tiny = AnnotateGeometry.arrow(from: .zero, to: CGPoint(x: 4, y: 0), lineWidth: 3, unit: 1)
        XCTAssertLessThanOrEqual(tiny.shaftEnd.x, 4, "a short arrow is all head, not a head sticking out the back")
    }

    func testLinesAreHitNearTheLineOnly() {
        let a = mark(.line, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        XCTAssertTrue(AnnotateGeometry.hit(a, at: CGPoint(x: 50, y: 3), tolerance: 4, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(a, at: CGPoint(x: 50, y: 20), tolerance: 4, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(a, at: CGPoint(x: 140, y: 0), tolerance: 4, unit: 1))
    }

    func testOutlinedBoxesAreHitOnTheirOutlineAndFilledOnesInside() {
        var box = mark(.rectangle, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 180, y: 120))
        XCTAssertTrue(AnnotateGeometry.hit(box, at: CGPoint(x: 20, y: 70), tolerance: 4, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(box, at: CGPoint(x: 100, y: 70), tolerance: 4, unit: 1), "the middle of an outline lets clicks through")
        box.style.filled = true
        XCTAssertTrue(AnnotateGeometry.hit(box, at: CGPoint(x: 100, y: 70), tolerance: 4, unit: 1))

        var oval = mark(.ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100))
        XCTAssertTrue(AnnotateGeometry.hit(oval, at: CGPoint(x: 100, y: 0), tolerance: 4, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(oval, at: CGPoint(x: 2, y: 2), tolerance: 4, unit: 1), "a corner of the bounding box is outside the oval")
        XCTAssertFalse(AnnotateGeometry.hit(oval, at: CGPoint(x: 100, y: 50), tolerance: 4, unit: 1))
        oval.style.filled = true
        XCTAssertTrue(AnnotateGeometry.hit(oval, at: CGPoint(x: 100, y: 50), tolerance: 4, unit: 1))
    }

    func testStepsPensAndHighlightsAreHit() {
        var step = mark(.step, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50))
        step.number = 1
        XCTAssertTrue(AnnotateGeometry.hit(step, at: CGPoint(x: 55, y: 52), tolerance: 2, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(step, at: CGPoint(x: 120, y: 50), tolerance: 2, unit: 1))

        var pen = mark(.pen, from: .zero, to: .zero)
        pen.points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 0)]
        XCTAssertTrue(AnnotateGeometry.hit(pen, at: CGPoint(x: 25, y: 26), tolerance: 4, unit: 1))
        XCTAssertFalse(AnnotateGeometry.hit(pen, at: CGPoint(x: 50, y: 5), tolerance: 4, unit: 1))

        let marker = mark(.highlight, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 30))
        XCTAssertTrue(AnnotateGeometry.hit(marker, at: CGPoint(x: 50, y: 20), tolerance: 4, unit: 1))
    }

    func testResizingPullsOnlyTheHeldHandleAndFlipsPastTheOppositeSide() {
        let box = CGRect(x: 20, y: 20, width: 100, height: 60)
        assertRect(AnnotateGeometry.resized(box, handle: .right, to: CGPoint(x: 200, y: 999)), 20, 20, 180, 60)
        assertRect(AnnotateGeometry.resized(box, handle: .topLeft, to: CGPoint(x: 0, y: 0)), 0, 0, 120, 80)
        assertRect(AnnotateGeometry.resized(box, handle: .left, to: CGPoint(x: 150, y: 0)), 120, 20, 30, 60)

        var line = mark(.arrow, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 10))
        line = AnnotateGeometry.resized(line, handle: .end, to: CGPoint(x: 90, y: 90))
        XCTAssertEqual(line.start, CGPoint(x: 10, y: 10), "only the dragged end moves")
        XCTAssertEqual(line.end, CGPoint(x: 90, y: 90))
    }

    func testMovingShiftsEveryPoint() {
        var pen = mark(.pen, from: .zero, to: .zero)
        pen.points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        let moved = AnnotateGeometry.moved(pen, by: CGSize(width: 10, height: -1))
        XCTAssertEqual(moved.points, [CGPoint(x: 11, y: 1), CGPoint(x: 13, y: 3)])
        XCTAssertEqual(moved.id, pen.id)
    }

    func testFittedKeepsTheCropInsideThePicture() {
        assertRect(AnnotateGeometry.fitted(CGRect(x: 150, y: -20, width: 100, height: 50), in: CGSize(width: 200, height: 100)), 100, 0, 100, 50)
        assertRect(AnnotateGeometry.fitted(CGRect(x: -5, y: -5, width: 900, height: 900), in: CGSize(width: 200, height: 100)), 0, 0, 200, 100)
    }

    func testSizesFollowThePicture() {
        XCTAssertEqual(AnnotateGeometry.unit(for: CGSize(width: 1800, height: 900)), 2, accuracy: 1e-9)
        XCTAssertEqual(AnnotateGeometry.unit(for: CGSize(width: 100, height: 50)), 0.6, accuracy: 1e-9, "tiny pictures never get hairline marks")
    }

    // MARK: Rendering

    func testRenderKeepsSizeAndOrientationAndWithNoMarksChangesNothing() {
        let image = picture(top: (255, 0, 0), bottom: (0, 0, 255))
        let out = render(image, [])
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 100)
        XCTAssertEqual(pixel(out, 100, 10).r, 255, "the top of the picture is still the top")
        XCTAssertEqual(pixel(out, 100, 10).b, 0)
        XCTAssertEqual(pixel(out, 100, 90).b, 255)
    }

    func testRectangleOutlineAndFillLandWhereTheyWereDragged() {
        let white = picture()
        var box = mark(.rectangle, from: CGPoint(x: 40, y: 20), to: CGPoint(x: 160, y: 80)) { $0.color = .blue; $0.width = 4 }
        var out = render(white, [box])
        XCTAssertEqual(pixel(out, 40, 50).b, 255)
        XCTAssertEqual(pixel(out, 40, 50).r, Int((AnnotationColor.blue.red * 255).rounded()), accuracy: 2)
        XCTAssertEqual(pixel(out, 100, 50).r, 255, "an outline leaves the inside alone")
        XCTAssertEqual(pixel(out, 100, 10).g, 255, "and the outside")

        box.style.filled = true
        out = render(white, [box])
        XCTAssertLessThan(pixel(out, 100, 50).r, 40, "a filled box is solid")
    }

    func testArrowDrawsAlongItsShaftAndHead() {
        let out = render(picture(), [mark(.arrow, from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50)) { $0.color = .red; $0.width = 4 }])
        XCTAssertLessThan(pixel(out, 60, 50).b, 80, "the shaft")
        XCTAssertLessThan(pixel(out, 170, 50).b, 80, "the head")
        XCTAssertEqual(pixel(out, 60, 30).b, 255, "nothing above the line")
    }

    func testTheShadowFallsBelowAMark() {
        // 900 pixels wide, so one canvas point is one pixel and the shadow is a few pixels deep.
        let box = mark(.rectangle, from: CGPoint(x: 300, y: 150), to: CGPoint(x: 600, y: 300)) { $0.shadow = true; $0.filled = true; $0.color = .white }
        let out = render(picture(width: 900, height: 450), [box])
        let below = pixel(out, 450, 303), above = pixel(out, 450, 147)
        XCTAssertLessThan(below.r, above.r, "a drop shadow sits under the mark, not over it")
    }

    func testHighlightLetsTheTextBelowShowThrough() {
        let out = render(picture(top: (0, 0, 0), bottom: (0, 0, 0)), [mark(.highlight, from: CGPoint(x: 20, y: 10), to: CGPoint(x: 180, y: 40)) { $0.color = .yellow }])
        let inside = pixel(out, 100, 25)
        XCTAssertGreaterThan(inside.r, 60)
        XCTAssertLessThan(inside.r, 200, "see-through, not solid")
        XCTAssertEqual(pixel(out, 100, 70).r, 0)
    }

    func testStepBadgeIsAColoredCircle() {
        var step = mark(.step, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 100, y: 50)) { $0.color = .green; $0.width = 4 }
        step.number = 3
        let out = render(picture(width: 200, height: 100), [step])
        let r = AnnotateGeometry.badgeRadius(step, unit: AnnotateGeometry.unit(for: CGSize(width: 200, height: 100)))
        let edge = pixel(out, 100 + Int(r * 0.8), 50)
        XCTAssertEqual(edge.g, Int((AnnotationColor.green.green * 255).rounded()), accuracy: 3)
        XCTAssertEqual(pixel(out, 100 + Int(r) + 6, 50).r, 255, "and nothing outside it")
    }

    func testTextIsDrawnWithItsColor() {
        var text = mark(.text, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)) { $0.color = .black; $0.textSize = 40 }
        text.text = "HELLO"
        let out = render(picture(width: 300, height: 100), [text])
        let size = AnnotateGeometry.textSize(of: text, unit: AnnotateGeometry.unit(for: CGSize(width: 300, height: 100)))
        var dark = 0
        for y in 10..<min(100, 10 + Int(size.height)) {
            for x in 10..<min(300, 10 + Int(size.width)) where pixel(out, x, y).r < 100 { dark += 1 }
        }
        XCTAssertGreaterThan(dark, 40, "the letters are there, in the picture's upper left, upright")
        XCTAssertEqual(pixel(out, 280, 90).r, 255)
    }

    func testBlurHidesThePictureButNeverTheOtherMarks() {
        let image = splitPicture()
        let blur = mark(.blur, from: CGPoint(x: 60, y: 10), to: CGPoint(x: 140, y: 90))
        // A hard black/white edge at x = 100; blurred, the pixels beside it must turn gray.
        let blurredOnly = render(image, [blur])
        XCTAssertEqual(pixel(blurredOnly, 20, 50).r, 0, "outside the region nothing changes")
        let nearEdge = pixel(blurredOnly, 96, 50).r
        XCTAssertGreaterThan(nearEdge, 25, "the edge is softened")
        XCTAssertLessThan(nearEdge, 235)

        // Added after the red box, blur still sits under it.
        let box = mark(.rectangle, from: CGPoint(x: 80, y: 30), to: CGPoint(x: 120, y: 70)) { $0.filled = true; $0.color = .red }
        let both = render(image, [box, blur])
        XCTAssertEqual(pixel(both, 100, 50).r, Int((AnnotationColor.red.red * 255).rounded()), accuracy: 2)
        XCTAssertEqual(pixel(both, 100, 50).g, Int((AnnotationColor.red.green * 255).rounded()), accuracy: 2, "the box is crisp, not blurred")
    }

    func testPixelateTurnsDetailIntoBlocks() {
        let image = splitPicture()
        let region = mark(.blur, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100)) { $0.blurStyle = .pixelate; $0.blurAmount = 3 }
        let out = render(image, [region])
        // Blocks are as wide as the effect says, so neighbors inside one block match.
        XCTAssertEqual(pixel(out, 10, 10).r, pixel(out, 11, 10).r)
        XCTAssertEqual(pixel(out, 10, 10).r, pixel(out, 10, 11).r)
    }

    func testBlurIsStrongerAtHigherAmounts() {
        let image = splitPicture(width: 400, height: 100)
        func softness(_ amount: Double) -> Int {
            let out = render(image, [mark(.blur, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 400, y: 100)) { $0.blurAmount = amount }])
            // How far from black the pixel 30 px left of the edge has drifted.
            return pixel(out, 170, 50).r
        }
        XCTAssertGreaterThan(softness(8), softness(2))
    }

    func testThumbnailScalesTheWholeDrawing() {
        let image = picture(width: 400, height: 200)
        let small = AnnotateRenderer.render(image: image, annotations: [mark(.rectangle, from: CGPoint(x: 100, y: 50), to: CGPoint(x: 300, y: 150)) { $0.filled = true; $0.color = .black }],
                                            blurs: AnnotateBlurCache(), scale: 0.5)!
        XCTAssertEqual(small.width, 200)
        XCTAssertEqual(small.height, 100)
        XCTAssertLessThan(pixel(small, 100, 50).r, 40, "the box is in the middle of the small copy too")
        XCTAssertEqual(pixel(small, 10, 10).r, 255)
    }

    func testOpaqueRenderFlattensOntoWhite() {
        let ctx = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let clear = ctx.makeImage()!
        let out = AnnotateRenderer.render(image: clear, annotations: [], blurs: AnnotateBlurCache(), opaque: true)!
        XCTAssertEqual(pixel(out, 5, 5).r, 255)
        XCTAssertEqual(pixel(out, 5, 5).a, 255)
    }

    // MARK: Files

    func testPNGAndJPEGRoundTrip() throws {
        let image = picture(top: (255, 0, 0), bottom: (0, 0, 255))
        for format in AnnotateFormat.allCases {
            let data = try AnnotateScreenshot.encode(image, as: format, quality: 0.9)
            let reader = CGImageSourceCreateWithData(data as CFData, nil)!
            XCTAssertEqual(CGImageSourceGetType(reader) as String?, format.type.identifier)
            let back = CGImageSourceCreateImageAtIndex(reader, 0, nil)!
            XCTAssertEqual(back.width, 200)
            XCTAssertEqual(back.height, 100)
        }
    }

    func testSavingNeverOverwrites() throws {
        let image = picture()
        let first = try AnnotateScreenshot.save(image, name: "Shot annotated", format: .png, quality: 1, into: dir)
        let second = try AnnotateScreenshot.save(image, name: "Shot annotated", format: .png, quality: 1, into: dir)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "Shot annotated.png")
        XCTAssertEqual(second.lastPathComponent, "Shot annotated 2.png")
        let jpeg = try AnnotateScreenshot.save(image, name: "Shot annotated", format: .jpeg, quality: 0.8, into: dir)
        XCTAssertEqual(jpeg.pathExtension, "jpg")
    }

    func testPastedImageDataIsRead() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("annotate-test-\(UUID())"))
        board.clearContents()
        board.setData(try AnnotateScreenshot.encode(picture(width: 64, height: 32), as: .png, quality: 1), forType: .png)
        let found = AnnotateScreenshot.image(from: board)
        XCTAssertEqual(found?.image.width, 64)
        XCTAssertEqual(found?.image.height, 32)

        let empty = NSPasteboard(name: NSPasteboard.Name("annotate-empty-\(UUID())"))
        empty.clearContents()
        empty.setString("just words", forType: .string)
        XCTAssertNil(AnnotateScreenshot.image(from: empty))
    }

    func testPastedImageFileIsReadWithItsName() throws {
        let url = dir.appendingPathComponent("Checkout flow.png")
        try AnnotateScreenshot.encode(picture(), as: .png, quality: 1).write(to: url)
        XCTAssertEqual(AnnotateScreenshot.load(url)?.width, 200)
        let board = NSPasteboard(name: NSPasteboard.Name("annotate-file-\(UUID())"))
        board.clearContents()
        board.writeObjects([url as NSURL])
        XCTAssertEqual(AnnotateScreenshot.image(from: board)?.name, "Checkout flow")
    }

    // MARK: Model

    @MainActor private func model(width: Int = 400, height: Int = 200) -> AnnotateScreenshotModel {
        let model = AnnotateScreenshotModel()
        model.open(image: picture(width: width, height: height), name: "Test")
        return model
    }

    @MainActor private func draw(_ kind: AnnotationTool, in model: AnnotateScreenshotModel, from a: CGPoint = CGPoint(x: 10, y: 10), to b: CGPoint = CGPoint(x: 60, y: 40)) -> Annotation {
        // The same steps the canvas takes for one drag.
        model.beginEdit()
        let mark = Annotation(kind: kind, start: a, end: b, style: model.style)
        model.add(mark)
        model.select(mark.id)
        model.endEdit()
        return mark
    }

    @MainActor func testOpeningNamesTheFileAfterTheOriginal() {
        let m = AnnotateScreenshotModel()
        XCTAssertFalse(m.hasDocument)
        m.open(image: picture(), name: "Checkout")
        XCTAssertEqual(m.document?.name, "Checkout annotated")
        m.open(image: picture())
        XCTAssertTrue(m.document?.name.hasPrefix("Annotated Screenshot ") == true)
    }

    @MainActor func testUndoAndRedoWalkThroughEveryDrawnMark() {
        let m = model()
        _ = draw(.arrow, in: m)
        _ = draw(.rectangle, in: m, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 150))
        XCTAssertEqual(m.annotations.count, 2)
        m.undo()
        XCTAssertEqual(m.annotations.map(\.kind), [.arrow])
        m.undo()
        XCTAssertTrue(m.annotations.isEmpty)
        XCTAssertFalse(m.canUndo)
        m.redo()
        m.redo()
        XCTAssertEqual(m.annotations.map(\.kind), [.arrow, .rectangle])
        XCTAssertFalse(m.canRedo)
        m.undo()
        _ = draw(.line, in: m)
        XCTAssertFalse(m.canRedo, "a new mark ends the redo trail")
    }

    @MainActor func testADragThatChangesNothingLeavesNoUndoStep() {
        let m = model()
        _ = draw(.arrow, in: m)
        m.undo()
        m.redo()
        m.beginEdit()
        m.endEdit()
        m.undo()
        XCTAssertTrue(m.annotations.isEmpty, "one undo takes back the mark, not an empty gesture before it")
    }

    @MainActor func testMovingAMarkIsOneUndoStep() {
        let m = model()
        let a = draw(.rectangle, in: m)
        m.beginEdit()
        for step in 1...5 { m.update(AnnotateGeometry.moved(a, by: CGSize(width: CGFloat(step) * 4, height: 0))) }
        m.endEdit()
        XCTAssertEqual(m.annotations[0].start.x, 30, accuracy: 1e-9)
        m.undo()
        XCTAssertEqual(m.annotations[0].start.x, 10, accuracy: 1e-9)
    }

    @MainActor func testStepsCountUpAndCloseTheGapWhenOneIsDeleted() {
        let m = model()
        var ids: [UUID] = []
        for i in 0..<3 {
            m.beginEdit()
            var step = Annotation(kind: .step, start: CGPoint(x: 20 + CGFloat(i) * 40, y: 20), end: CGPoint(x: 20, y: 20), style: m.style)
            step.number = m.nextStepNumber
            m.add(step)
            m.endEdit()
            ids.append(step.id)
        }
        XCTAssertEqual(m.annotations.map(\.number), [1, 2, 3])
        XCTAssertEqual(m.nextStepNumber, 4)
        m.select(ids[1])
        m.deleteSelected()
        XCTAssertEqual(m.annotations.map(\.number), [1, 2])
        XCTAssertEqual(m.nextStepNumber, 3)
        m.undo()
        XCTAssertEqual(m.annotations.map(\.number), [1, 2, 3], "undo brings the numbers back too")
    }

    @MainActor func testSelectingAMarkLoadsItsStyleAndRestylingChangesIt() {
        let m = model()
        m.restyle { $0.color = .blue; $0.width = 8 }
        let a = draw(.arrow, in: m)
        m.restyle { $0.color = .green }
        m.select(nil)
        m.restyle { $0.color = .purple }
        XCTAssertEqual(m.annotations[0].style.color, .green, "with nothing selected only the next mark changes")
        m.select(a.id)
        XCTAssertEqual(m.style.color, .green)
        XCTAssertEqual(m.style.width, 8)
        m.restyle { $0.shadow = false }
        XCTAssertFalse(m.annotations[0].style.shadow)
    }

    @MainActor func testDraggingASliderIsOneUndoStep() {
        let m = model()
        _ = draw(.arrow, in: m)
        for w in 4...10 { m.restyle { $0.width = Double(w) } }
        XCTAssertEqual(m.annotations[0].style.width, 10)
        m.undo()
        XCTAssertEqual(m.annotations[0].style.width, 3, "back to before the whole drag")
    }

    @MainActor func testHighlighterIsYellowAndGivesTheOldColorBack() {
        let m = model()
        m.restyle { $0.color = .purple }
        m.setTool(.highlight)
        XCTAssertEqual(m.style.color, .yellow)
        m.setTool(.arrow)
        XCTAssertEqual(m.style.color, .purple)
    }

    @MainActor func testToolsOtherThanSelectDropTheSelection() {
        let m = model()
        let a = draw(.rectangle, in: m)
        m.setTool(.select)
        m.select(a.id)
        XCTAssertNotNil(m.selected)
        m.setTool(.arrow)
        XCTAssertNil(m.selected)
    }

    @MainActor func testDuplicateReorderAndDeleteWork() {
        let m = model()
        let a = draw(.rectangle, in: m)
        let b = draw(.ellipse, in: m, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 150, y: 140))
        m.select(a.id)
        m.bringToFront()
        XCTAssertEqual(m.annotations.last?.id, a.id)
        m.sendToBack()
        XCTAssertEqual(m.annotations.first?.id, a.id)
        m.duplicateSelected()
        XCTAssertEqual(m.annotations.count, 3)
        XCTAssertNotEqual(m.selected?.id, a.id)
        XCTAssertGreaterThan(m.selected!.start.x, a.start.x, "the copy sits a little aside")
        m.deleteSelected()
        XCTAssertEqual(m.annotations.map(\.id).contains(b.id), true)
        XCTAssertEqual(m.annotations.count, 2)
    }

    @MainActor func testCropKeepsTheChosenAreaAndCarriesMarksAlong() {
        let m = model(width: 400, height: 200)
        let a = draw(.rectangle, in: m, from: CGPoint(x: 150, y: 80), to: CGPoint(x: 250, y: 140))
        m.setTool(.crop)
        XCTAssertEqual(m.cropRect, CGRect(x: 0, y: 0, width: 400, height: 200), "the whole picture to begin with")
        XCTAssertFalse(m.cropChanged)
        m.setCrop(CGRect(x: 100, y: 50, width: 200, height: 120))
        XCTAssertTrue(m.cropChanged)
        m.applyCrop()
        XCTAssertEqual(m.pixelSize, CGSize(width: 200, height: 120))
        XCTAssertEqual(m.annotations[0].start, CGPoint(x: 50, y: 30), "the box keeps its place on the picture")
        XCTAssertEqual(m.annotations[0].id, a.id)
        XCTAssertEqual(m.tool, .select)
        m.undo()
        XCTAssertEqual(m.pixelSize, CGSize(width: 400, height: 200))
        XCTAssertEqual(m.annotations[0].start, CGPoint(x: 150, y: 80))
        m.redo()
        XCTAssertEqual(m.pixelSize, CGSize(width: 200, height: 120))
    }

    @MainActor func testCropCannotLeaveThePictureAndCancelChangesNothing() {
        let m = model(width: 400, height: 200)
        m.setTool(.crop)
        m.setCrop(CGRect(x: 300, y: 150, width: 500, height: 500))
        XCTAssertLessThanOrEqual(m.cropRect!.maxX, 400)
        XCTAssertLessThanOrEqual(m.cropRect!.maxY, 200)
        m.cancelCrop()
        XCTAssertNil(m.cropRect)
        XCTAssertEqual(m.pixelSize, CGSize(width: 400, height: 200))
        XCTAssertFalse(m.canUndo)
    }

    @MainActor func testApplyingAnUnchangedCropIsANoOp() {
        let m = model()
        m.setTool(.crop)
        m.applyCrop()
        XCTAssertFalse(m.canUndo)
        XCTAssertEqual(m.pixelSize, CGSize(width: 400, height: 200))
    }

    @MainActor func testOpeningAnotherPictureCanBeUndone() {
        let m = model(width: 400, height: 200)
        _ = draw(.arrow, in: m)
        m.open(image: picture(width: 50, height: 50), name: "Other")
        XCTAssertEqual(m.pixelSize, CGSize(width: 50, height: 50))
        XCTAssertTrue(m.annotations.isEmpty)
        m.undo()
        XCTAssertEqual(m.pixelSize, CGSize(width: 400, height: 200))
        XCTAssertEqual(m.annotations.count, 1, "the earlier picture comes back with its marks")
    }

    @MainActor func testTextWithNoWordsIsDroppedAndTypedTextStays() {
        let m = model()
        m.beginEdit()
        let empty = Annotation(kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 10), style: m.style)
        m.add(empty)
        m.beginTextEditing(empty.id)
        m.commitText("", for: empty.id)
        XCTAssertTrue(m.annotations.isEmpty)
        XCTAssertFalse(m.canUndo, "an abandoned text leaves no trace")

        m.beginEdit()
        let typed = Annotation(kind: .text, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 10, y: 10), style: m.style)
        m.add(typed)
        m.beginTextEditing(typed.id)
        m.commitText("Click here", for: typed.id)
        XCTAssertEqual(m.annotations.first?.text, "Click here")
        XCTAssertNil(m.editingID)
        m.undo()
        XCTAssertTrue(m.annotations.isEmpty, "one undo takes the whole text back")
    }

    @MainActor func testRenderedImageHasEveryMarkAtFullSize() {
        let m = model(width: 400, height: 200)
        var style = AnnotationStyle()
        style.shadow = false
        style.filled = true
        style.color = .black
        m.beginEdit()
        m.add(Annotation(kind: .rectangle, start: CGPoint(x: 100, y: 50), end: CGPoint(x: 300, y: 150), style: style))
        m.endEdit()
        let png = m.rendered()!
        XCTAssertEqual(png.width, 400)
        XCTAssertLessThan(pixel(png, 200, 100).r, 40)
        m.format = .jpeg
        XCTAssertEqual(m.rendered()!.alphaInfo, .noneSkipLast, "JPEG gets a flat picture")
    }

    /// The canvas draws with the same renderer, so its shadow must fall the same way as the saved file's.
    @MainActor func testOnScreenShadowFallsBelowAMarkToo() throws {
        let m = AnnotateScreenshotModel()
        m.open(image: picture(width: 900, height: 450), name: "Shadow")
        var style = AnnotationStyle()
        style.filled = true
        style.color = .white
        m.add(Annotation(kind: .rectangle, start: CGPoint(x: 300, y: 150), end: CGPoint(x: 600, y: 300), style: style))
        let canvas = AnnotateCanvasView(model: m)
        canvas.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / canvas.bounds.width
        // The picture is shown at 856/900 of its size, 22 points in from the left and centered from the top.
        let scale = 856.0 / 900
        let top = 36 + 150 * scale, bottom = 36 + 300 * scale
        func light(_ y: CGFloat) -> CGFloat { rep.colorAt(x: Int(450 * k), y: Int(y * k))!.usingColorSpace(.sRGB)!.redComponent }
        XCTAssertLessThan(light(bottom + 3), light(top - 3), "below the mark is darker than above it")
    }

    @MainActor func testSavingWritesANewFileAndKeepsTheOriginal() throws {
        let original = dir.appendingPathComponent("Original.png")
        try AnnotateScreenshot.encode(picture(), as: .png, quality: 1).write(to: original)
        let before = try Data(contentsOf: original)
        let m = AnnotateScreenshotModel()
        m.open(url: original)
        XCTAssertEqual(m.document?.name, "Original annotated")
        let saved = try AnnotateScreenshot.save(m.rendered()!, name: m.document!.name, format: .png, quality: 1, into: dir)
        XCTAssertEqual(saved.lastPathComponent, "Original annotated.png")
        XCTAssertEqual(try Data(contentsOf: original), before)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(a) is not within \(accuracy) of \(b)", file: file, line: line)
}
