import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Toolbox

final class ScanDocumentTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("scan-document-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Page sizes

    func testMatchTheScanKeepsTheShapeAndFixesTheLongerSide() {
        let size = ScanPageSize.matchScan.pageSize(forImage: CGSize(width: 1500, height: 2000))
        XCTAssertEqual(size.height, 841.89, accuracy: 0.01)
        XCTAssertEqual(size.width / size.height, 0.75, accuracy: 0.001)
        let wide = ScanPageSize.matchScan.pageSize(forImage: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(wide.width, 841.89, accuracy: 0.01)
        XCTAssertEqual(wide.height, 420.945, accuracy: 0.01)
    }

    func testSheetsTurnSidewaysForAWidePicture() {
        XCTAssertEqual(ScanPageSize.a4.pageSize(forImage: CGSize(width: 100, height: 200)), CGSize(width: 595.28, height: 841.89))
        XCTAssertEqual(ScanPageSize.a4.pageSize(forImage: CGSize(width: 200, height: 100)), CGSize(width: 841.89, height: 595.28))
        XCTAssertEqual(ScanPageSize.letter.pageSize(forImage: CGSize(width: 100, height: 200)), CGSize(width: 612, height: 792))
        XCTAssertEqual(ScanPageSize.letter.pageSize(forImage: CGSize(width: 200, height: 100)), CGSize(width: 792, height: 612))
    }

    // MARK: Straightening

    func testStraightenCutsOutTheSkewedPageAndDropsTheBackground() throws {
        let corners = PageCorners(topLeft: CGPoint(x: 0.15, y: 0.85), topRight: CGPoint(x: 0.85, y: 0.9),
                                  bottomRight: CGPoint(x: 0.9, y: 0.12), bottomLeft: CGPoint(x: 0.1, y: 0.15))
        let photo = try makePhotoOfPaper(corners: corners)
        let straight = DocumentScanner.straighten(photo, corners: corners)

        XCTAssertLessThan(straight.width, photo.width)
        XCTAssertGreaterThan(straight.width, 400)
        // Inside the cut-out every corner is paper; the dark desk is gone.
        for (fx, fy) in [(0.03, 0.03), (0.97, 0.03), (0.03, 0.97), (0.97, 0.97), (0.5, 0.5)] {
            let p = try pixel(straight, x: Int(Double(straight.width) * fx), y: Int(Double(straight.height) * fy))
            XCTAssertGreaterThan(Int(p[0]) + Int(p[1]) + Int(p[2]), 3 * 150, "corner (\(fx), \(fy)) is not paper: \(p)")
        }
    }

    func testASkewedPageOnADeskIsFoundAndScannedUpright() throws {
        let corners = PageCorners(topLeft: CGPoint(x: 0.15, y: 0.85), topRight: CGPoint(x: 0.85, y: 0.9),
                                  bottomRight: CGPoint(x: 0.9, y: 0.12), bottomLeft: CGPoint(x: 0.1, y: 0.15))
        let photo = try makePhotoOfPaper(corners: corners)
        let found = try XCTUnwrap(DocumentScanner.detectPage(in: photo), "Vision found no page")
        for (a, b) in [(found.topLeft, corners.topLeft), (found.topRight, corners.topRight),
                       (found.bottomRight, corners.bottomRight), (found.bottomLeft, corners.bottomLeft)] {
            XCTAssertEqual(a.x, b.x, accuracy: 0.05)
            XCTAssertEqual(a.y, b.y, accuracy: 0.05)
        }
        let scanned = DocumentScanner.scan(photo: photo)
        XCTAssertTrue(scanned.foundEdges)
        XCTAssertLessThan(scanned.image.width, photo.width)
    }

    func testAPageThatFillsThePhotoIsLeftAlone() throws {
        let photo = try makePage(width: 600, height: 800, text: nil)
        let whole = PageCorners(topLeft: CGPoint(x: 0, y: 1), topRight: CGPoint(x: 1, y: 1), bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 0))
        let straight = DocumentScanner.straighten(photo, corners: whole)
        XCTAssertEqual(straight.width, 600)
        XCTAssertEqual(straight.height, 800)
    }

    func testTinyAreasAreNotTakenForAPage() {
        let small = PageCorners(topLeft: CGPoint(x: 0.4, y: 0.6), topRight: CGPoint(x: 0.6, y: 0.6), bottomRight: CGPoint(x: 0.6, y: 0.4), bottomLeft: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(small.area, 0.04, accuracy: 0.0001)
        XCTAssertFalse(small.isUsable)
    }

    // MARK: Looks

    func testColorTurnsShadedPaperWhiteAndKeepsColors() throws {
        let page = try makeShadedPage()
        let image = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 0, look: .color, maxPixel: 4096))
        // The dark left edge of the paper (about 55% bright before) is white now.
        let paper = try pixel(image, x: 20, y: 500)
        XCTAssertGreaterThan(Int(paper[0]), 235); XCTAssertGreaterThan(Int(paper[1]), 235); XCTAssertGreaterThan(Int(paper[2]), 235)
        // The red patch stays red.
        let red = try pixel(image, x: 600, y: 235)
        XCTAssertGreaterThan(Int(red[0]), 170)
        XCTAssertLessThan(Int(red[1]), 110)
        XCTAssertLessThan(Int(red[2]), 110)
        // Ink stays dark.
        XCTAssertLessThan(Int(try pixel(image, x: 100, y: 745)[0]), 90)
    }

    func testGrayscaleIsOneChannelWithEvenPaper() throws {
        let page = try makeShadedPage()
        let image = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 0, look: .grayscale, maxPixel: 4096))
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertGreaterThan(Int(try pixel(image, x: 20, y: 500)[0]), 235)
        XCTAssertGreaterThan(Int(try pixel(image, x: 780, y: 500)[0]), 235)
    }

    func testBlackAndWhiteHasOnlyBlackAndWhite() throws {
        let page = try makeShadedPage()
        let image = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 0, look: .blackAndWhite, maxPixel: 4096))
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        XCTAssertEqual(try pixel(image, x: 20, y: 500)[0], 255)
        XCTAssertEqual(try pixel(image, x: 100, y: 745)[0], 0)
        var other = 0
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) where ![0, 255].contains(try pixel(image, x: x, y: y)[0]) { other += 1 }
        }
        XCTAssertEqual(other, 0)
    }

    func testTurnsRotateClockwiseAndAreCappedBySize() throws {
        let page = try makePage(width: 600, height: 800, text: nil)
        let turned = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 1, look: .color, maxPixel: 4096))
        XCTAssertEqual(turned.width, 800)
        XCTAssertEqual(turned.height, 600)
        let backwards = try XCTUnwrap(DocumentScanner.bitmap(page, turns: -1, look: .color, maxPixel: 4096))
        XCTAssertEqual(backwards.width, 800)
        let capped = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 0, look: .color, maxPixel: 400))
        XCTAssertEqual(max(capped.width, capped.height), 400)
        XCTAssertEqual(Double(capped.width) / Double(capped.height), 0.75, accuracy: 0.01)
    }

    func testTheClockwiseTurnPutsTheTopOnTheRight() throws {
        // Black bar along the top of an otherwise white page.
        let context = try bitmapContext(width: 400, height: 600)
        context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 560, width: 400, height: 40))
        let page = try XCTUnwrap(context.makeImage())
        let turned = try XCTUnwrap(DocumentScanner.bitmap(page, turns: 1, look: .color, maxPixel: 4096))
        XCTAssertLessThan(Int(try pixel(turned, x: turned.width - 10, y: turned.height / 2)[0]), 100)
        XCTAssertGreaterThan(Int(try pixel(turned, x: 10, y: turned.height / 2)[0]), 200)
    }

    // MARK: PDF

    func testEveryPageBecomesAPageWithTheChosenSize() throws {
        let tall = ScanExportPage(image: try makePage(width: 600, height: 800, text: nil), turns: 0)
        let turned = ScanExportPage(image: try makePage(width: 600, height: 800, text: nil), turns: 1)

        let letter = try pdf([tall, turned], pageSize: .letter)
        XCTAssertEqual(letter.pageCount, 2)
        XCTAssertEqual(letter.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertEqual(letter.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 792, height: 612))

        let matched = try pdf([tall, turned], pageSize: .matchScan)
        let first = try XCTUnwrap(matched.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(first.height, 841.89, accuracy: 0.01)
        XCTAssertEqual(first.width / first.height, 0.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(matched.page(at: 1)?.bounds(for: .mediaBox).size).width, 841.89, accuracy: 0.01)
    }

    func testSearchableAddsHiddenTextWhereItIsPrinted() throws {
        let page = ScanExportPage(image: try makePage(width: 1700, height: 2200, text: "Invoice 2841 Total Due"), turns: 0)

        let searchable = try pdf([page], pageSize: .letter, searchable: true)
        XCTAssertTrue((searchable.string ?? "").localizedCaseInsensitiveContains("invoice"), "text was: \(searchable.string ?? "nil")")
        let hit = try XCTUnwrap(searchable.findString("Invoice", withOptions: .caseInsensitive).first)
        let box = hit.bounds(for: try XCTUnwrap(searchable.page(at: 0)))
        // The text is printed near the top of the page, and the hidden text sits on it.
        XCTAssertGreaterThan(box.midY, 792 * 0.7)
        XCTAssertLessThan(box.minX, 612 * 0.4)

        let plain = try pdf([page], pageSize: .letter, searchable: false)
        XCTAssertTrue((plain.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testBlackAndWhiteMakesTheSmallestFile() throws {
        let page = ScanExportPage(image: try makeShadedPage(), turns: 0)
        let sizes = try ScanLook.allCases.map { look in
            (look, try DocumentScanner.makePDF(pages: [page], look: look, pageSize: .matchScan, searchable: false).count)
        }
        let bytes = Dictionary(uniqueKeysWithValues: sizes)
        XCTAssertLessThan(try XCTUnwrap(bytes[.blackAndWhite]), try XCTUnwrap(bytes[.color]))
        XCTAssertLessThan(try XCTUnwrap(bytes[.blackAndWhite]), try XCTUnwrap(bytes[.grayscale]))
    }

    func testProgressCountsPages() throws {
        let page = ScanExportPage(image: try makePage(width: 300, height: 400, text: nil), turns: 0)
        var done: [Int] = []
        _ = try DocumentScanner.makePDF(pages: [page, page, page], look: .color, pageSize: .a4, searchable: false) { done.append($0) }
        XCTAssertEqual(done, [1, 2, 3])
    }

    // MARK: Reading files

    func testPhotosPDFsAndFoldersAreAllReadAsPages() throws {
        let photo = dir.appendingPathComponent("page.jpg")
        try writeJPEG(try makePage(width: 600, height: 800, text: "Receipt"), to: photo)
        let pdfURL = dir.appendingPathComponent("scan.pdf")
        try DocumentScanner.makePDF(pages: [ScanExportPage(image: try makePage(width: 300, height: 400, text: nil), turns: 0),
                                            ScanExportPage(image: try makePage(width: 300, height: 400, text: nil), turns: 0)],
                                    look: .color, pageSize: .a4, searchable: false).write(to: pdfURL)
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)

        XCTAssertEqual(DocumentScanner.scan(file: photo).count, 1)
        let pdfPages = DocumentScanner.scan(file: pdfURL)
        XCTAssertEqual(pdfPages.count, 2)
        // A PDF page is drawn white, not clear.
        XCTAssertGreaterThan(Int(try pixel(pdfPages[0].image, x: 5, y: 5)[0]), 240)
        XCTAssertEqual(DocumentScanner.scan(file: notes).count, 0)
        XCTAssertEqual(DocumentScanner.scan(file: dir.appendingPathComponent("missing.jpg")).count, 0)
        XCTAssertEqual(DocumentScanner.scan(file: dir).count, 3)
    }

    func testPhotoTurnedByItsRotationTagIsReadUpright() throws {
        let url = dir.appendingPathComponent("sideways.jpg")
        try writeJPEG(try makePage(width: 600, height: 800, text: nil), to: url, orientation: 6)
        let image = try XCTUnwrap(DocumentScanner.load(url))
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 600)
    }

    // MARK: Model

    @MainActor func testPagesAreAddedInOrderAndCanBeReorderedTurnedAndRemoved() async throws {
        let model = ScanDocumentModel()
        let sizes = [(400, 500), (420, 520), (440, 540)]
        model.enqueue(try sizes.map { .photo(try makePage(width: $0.0, height: $0.1, text: nil)) })
        try await settle(model)

        XCTAssertEqual(model.pages.count, 3)
        let ids = model.pages.map(\.id)
        // Each is a plain white photo, so edge finding may trim a pixel or two; the order is what matters.
        XCTAssertEqual(model.pages.map(\.image.width).sorted(), model.pages.map(\.image.width))
        XCTAssertTrue(zip(model.pages.map(\.image.width), [400, 420, 440]).allSatisfy { abs($0 - $1) < 20 })

        model.move(ids[0], to: ids[2])
        XCTAssertEqual(model.pages.map(\.id), [ids[1], ids[2], ids[0]])
        model.move(ids[0], to: ids[1])
        XCTAssertEqual(model.pages.map(\.id), [ids[0], ids[1], ids[2]])
        model.move(ids[1], to: ids[1])
        XCTAssertEqual(model.pages.map(\.id), [ids[0], ids[1], ids[2]])
        XCTAssertEqual(model.number(of: ids[2]), 3)

        model.rotate(ids[1], by: 1)
        model.rotate(ids[1], by: 1)
        model.rotate(ids[1], by: 3)
        XCTAssertEqual(model.pages[1].turns, 1)
        model.rotate(ids[0], by: -1)
        XCTAssertEqual(model.pages[0].turns, 3)

        model.remove(ids[1])
        XCTAssertEqual(model.pages.map(\.id), [ids[0], ids[2]])
        model.clear()
        XCTAssertTrue(model.pages.isEmpty)
    }

    @MainActor func testThumbnailsFollowTheLookAndTurns() async throws {
        let model = ScanDocumentModel()
        model.enqueue([.photo(try makePage(width: 400, height: 600, text: nil))])
        try await settle(model)
        let id = try XCTUnwrap(model.pages.first?.id)
        try await until { model.thumbnails[id] != nil }
        XCTAssertEqual(model.thumbnails[id]?.colorSpace?.model, .rgb)

        model.settings.look = .blackAndWhite
        try await until { model.thumbnails[id]?.colorSpace?.model == .monochrome }

        model.rotate(id, by: 1)
        try await until { (model.thumbnails[id]?.width ?? 0) > (model.thumbnails[id]?.height ?? 1) }
    }

    @MainActor func testScannedPDFsFromAnIPhoneAddOnePagePerSheet() async throws {
        let data = try DocumentScanner.makePDF(pages: [ScanExportPage(image: try makePage(width: 300, height: 400, text: nil), turns: 0),
                                                       ScanExportPage(image: try makePage(width: 300, height: 400, text: nil), turns: 0)],
                                               look: .color, pageSize: .a4, searchable: false)
        let model = ScanDocumentModel()
        model.enqueue([.pdf(data)])
        try await settle(model)
        XCTAssertEqual(model.pages.count, 2)
        XCTAssertTrue(model.pages.allSatisfy(\.foundEdges))
    }

    @MainActor func testItemsWithNoPagesAreReported() async throws {
        let model = ScanDocumentModel()
        let notes = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: notes)
        model.add([notes, dir.appendingPathComponent("gone.jpg")])
        try await settle(model)
        XCTAssertTrue(model.pages.isEmpty)
        XCTAssertEqual(model.notice, "2 items had no pages and were skipped.")
    }

    @MainActor func testChangingSettingsForgetsTheLastSavedFile() async throws {
        let model = ScanDocumentModel()
        model.settings.makeSearchable = false
        XCTAssertNil(model.saved)
        XCTAssertFalse(model.settings.makeSearchable)
    }

    // MARK: Helpers

    @MainActor private func settle(_ model: ScanDocumentModel) async throws {
        try await until { !model.isAdding }
    }

    @MainActor private func until(timeout: TimeInterval = 60, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func pdf(_ pages: [ScanExportPage], pageSize: ScanPageSize, searchable: Bool = false) throws -> PDFDocument {
        let data = try DocumentScanner.makePDF(pages: pages, look: .color, pageSize: pageSize, searchable: searchable)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func bitmapContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    /// A white page, with a line of large black text near the top when `text` is given.
    private func makePage(width: Int, height: Int, text: String?) throws -> CGImage {
        let context = try bitmapContext(width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text { drawText(text, in: context, at: CGPoint(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.88), size: CGFloat(width) * 0.055) }
        return try XCTUnwrap(context.makeImage())
    }

    private func drawText(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
        context.setFillColor(gray: 0, alpha: 1)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    /// 800x1000 paper that is darker on the left (55%) than on the right, with a line of ink, a red patch and a few text-like bars.
    private func makeShadedPage() throws -> CGImage {
        let (w, h) = (800, 1000)
        let context = try bitmapContext(width: w, height: h)
        for x in stride(from: 0, to: w, by: 4) {
            let shade = 0.55 + 0.45 * CGFloat(x) / CGFloat(w)
            context.setFillColor(gray: shade, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 4, height: h))
        }
        context.setFillColor(gray: 0.05, alpha: 1)
        for row in 0..<14 { context.fill(CGRect(x: 80, y: 700 - row * 30, width: 560, height: 6)) }
        context.fill(CGRect(x: 80, y: 252, width: 300, height: 6))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 580, y: 740, width: 120, height: 50))
        return try XCTUnwrap(context.makeImage())
    }

    /// A 1200x1600 photo: a dark desk with a white page lying on it at `corners`, lines of text on the page.
    private func makePhotoOfPaper(corners: PageCorners) throws -> CGImage {
        let (w, h) = (1200, 1600)
        let context = try bitmapContext(width: w, height: h)
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func p(_ c: CGPoint) -> CGPoint { CGPoint(x: c.x * CGFloat(w), y: c.y * CGFloat(h)) }
        context.move(to: p(corners.topLeft))
        context.addLine(to: p(corners.topRight))
        context.addLine(to: p(corners.bottomRight))
        context.addLine(to: p(corners.bottomLeft))
        context.closePath()
        context.setFillColor(gray: 0.97, alpha: 1)
        context.fillPath()
        return try XCTUnwrap(context.makeImage())
    }

    /// RGBA of one pixel, `y` counted from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        // Draw the image shifted so that pixel (x, y) lands on the single pixel.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return out
    }

    private func writeJPEG(_ image: CGImage, to url: URL, orientation: Int = 1) throws {
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
    }
}
