import CoreText
import PDFKit
import XCTest
@testable import Toolbox

final class RedactPDFTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("redact-pdf-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Finding

    func testFindLocatesTheWordOnTheUprightPageWhateverTheRotation() throws {
        for rotation in [0, 90, 180, 270] {
            let url = try makePDF(pages: [[Line("Appleseed", x: 90, y: 520, size: 40)]], rotation: rotation)
            let document = try RedactPDF.open(url)
            let found = RedactPDF.find("appleseed", in: document)
            XCTAssertEqual(found.matches.count, 1, "rotation \(rotation)")
            let match = try XCTUnwrap(found.matches.first)
            let ink = try inkBounds(of: render(document, page: 0))
            XCTAssertTrue(match.rect.insetBy(dx: -0.005, dy: -0.005).contains(ink), "rotation \(rotation): \(match.rect) does not hold the word at \(ink)")
            XCTAssertLessThan(match.rect.width, 0.6, "rotation \(rotation): the box is far bigger than the word")
        }
    }

    func testFindFollowsTheCropBoxWhenItDoesNotStartAtTheCorner() throws {
        let url = try makePDF(pages: [[Line("Appleseed", x: 140, y: 400, size: 30)]], crop: CGRect(x: 100, y: 300, width: 400, height: 300))
        let document = try RedactPDF.open(url)
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: document).matches.first)
        let ink = try inkBounds(of: render(document, page: 0))
        XCTAssertTrue(match.rect.insetBy(dx: -0.005, dy: -0.005).contains(ink), "\(match.rect) does not hold the word at \(ink)")
        XCTAssertEqual(RedactPDF.uprightSize(of: try XCTUnwrap(document.page(at: 0))), CGSize(width: 400, height: 300))
    }

    func testFindCoversEveryMatchOnEveryPageIgnoringCase() throws {
        let url = try makePDF(pages: [
            [Line("The Secret is out", x: 72, y: 700, size: 20), Line("A secret again", x: 72, y: 600, size: 20)],
            [Line("SECRET", x: 72, y: 500, size: 20), Line("Nothing here", x: 72, y: 400, size: 20)],
        ])
        let found = RedactPDF.find("secret", in: try RedactPDF.open(url))
        XCTAssertEqual(found.matches.map(\.page).sorted(), [0, 0, 1])
        XCTAssertEqual(found.scannedPages, 0)
        XCTAssertEqual(RedactPDF.find("   ", in: try RedactPDF.open(url)).matches.count, 0, "a blank search finds nothing")
        XCTAssertEqual(RedactPDF.find("absent", in: try RedactPDF.open(url)).matches.count, 0)
    }

    func testFindReadsPagesThatAreOnlyAPicture() throws {
        let url = try makeScannedPDF(text: "Appleseed", size: 64)
        let document = try RedactPDF.open(url)
        XCTAssertFalse(RedactPDF.hasText(try XCTUnwrap(document.page(at: 0))), "the test page must have no text layer")
        let found = RedactPDF.find("Appleseed", in: document)
        XCTAssertEqual(found.scannedPages, 1)
        let match = try XCTUnwrap(found.matches.first, "Vision found no match")
        let ink = try inkBounds(of: render(document, page: 0))
        XCTAssertTrue(match.rect.insetBy(dx: -0.01, dy: -0.01).contains(ink), "\(match.rect) does not hold the word at \(ink)")
    }

    // MARK: Exporting

    func testRedactedTextIsGoneFromTheCopyNotJustCovered() throws {
        let source = try makePDF(pages: [[Line("Invoice 2041", x: 72, y: 700, size: 36), Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first)
        XCTAssertNotNil(try RedactPDF.open(source).findString("Appleseed", withOptions: []).first, "the source has the word as text")

        let output = dir.appendingPathComponent("out.pdf")
        let result = try RedactPDF.export(source: source, regions: [0: [match.rect]], keepSearchable: false, to: output)

        let copy = try RedactPDF.open(output)
        XCTAssertEqual(result.redactedPages, 1)
        XCTAssertTrue(copy.findString("Appleseed", withOptions: [.caseInsensitive]).isEmpty, "search still finds the name")
        XCTAssertFalse(RedactPDF.hasText(try XCTUnwrap(copy.page(at: 0))), "the page still has a text layer")
        XCTAssertNil(try XCTUnwrap(copy.page(at: 0)).selection(for: CGRect(x: 0, y: 0, width: 612, height: 792))?.string?.nonEmpty)
        let picture = try render(copy, page: 0)
        XCTAssertTrue(RedactPDF.isBlack(picture, at: CGPoint(x: match.rect.midX, y: match.rect.midY)), "no black box where the name was")
        XCTAssertGreaterThan(try inkCount(picture, in: CGRect(x: 0.05, y: 0.08, width: 0.5, height: 0.07)), 30, "the other text is no longer drawn")
    }

    func testKeepingTheRestSearchableRecognizesWhatIsStillVisible() throws {
        let source = try makePDF(pages: [[Line("Invoice 2041", x: 72, y: 700, size: 40), Line("Jane Appleseed", x: 72, y: 600, size: 40)]])
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first)
        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [match.rect]], keepSearchable: true, to: output)

        let copy = try RedactPDF.open(output)
        XCTAssertFalse(copy.findString("Invoice", withOptions: [.caseInsensitive]).isEmpty, "the visible text should be searchable again")
        XCTAssertTrue(copy.findString("Appleseed", withOptions: [.caseInsensitive]).isEmpty, "the redacted name must not come back")
        XCTAssertFalse((copy.string ?? "").localizedCaseInsensitiveContains("Appleseed"))
    }

    func testPagesWithoutBoxesAreCopiedAsTheyAre() throws {
        let source = try makePDF(pages: [
            [Line("Jane Appleseed", x: 72, y: 600, size: 28)],
            [Line("Second page text", x: 72, y: 600, size: 28)],
        ])
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first)
        let output = dir.appendingPathComponent("out.pdf")
        let result = try RedactPDF.export(source: source, regions: [0: [match.rect]], keepSearchable: false, to: output)

        let copy = try RedactPDF.open(output)
        XCTAssertEqual(copy.pageCount, 2)
        XCTAssertEqual(result.pages, 2)
        XCTAssertEqual(result.redactedPages, 1)
        XCTAssertTrue(try XCTUnwrap(copy.page(at: 1)).string?.contains("Second page text") ?? false, "the untouched page keeps its real text")
        XCTAssertEqual(RedactPDF.uprightSize(of: try XCTUnwrap(copy.page(at: 0))).width, 612, accuracy: 0.5)
        XCTAssertEqual(result.bytes, Int64(try Data(contentsOf: output).count))
    }

    func testAPageTurnedSidewaysComesBackUprightWithItsBoxInTheRightPlace() throws {
        for rotation in [90, 180, 270] {
            let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]], rotation: rotation)
            let document = try RedactPDF.open(source)
            let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: document).matches.first)
            let output = dir.appendingPathComponent("out-\(rotation).pdf")
            _ = try RedactPDF.export(source: source, regions: [0: [match.rect]], keepSearchable: false, to: output)

            let copy = try RedactPDF.open(output)
            let page = try XCTUnwrap(copy.page(at: 0))
            XCTAssertEqual(page.rotation, 0)
            XCTAssertEqual(RedactPDF.uprightSize(of: page), RedactPDF.uprightSize(of: try XCTUnwrap(document.page(at: 0))))
            XCTAssertTrue(RedactPDF.isBlack(try render(copy, page: 0), at: CGPoint(x: match.rect.midX, y: match.rect.midY)), "rotation \(rotation)")
        }
    }

    func testTheCopyCarriesNoneOfTheOriginalsDetails() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]], title: "Quarterly Secret Report", author: "Jane Metadata")
        let original = try RedactPDF.open(source)
        XCTAssertEqual(original.documentAttributes?["Author"] as? String, "Jane Metadata", "the source must have the details to begin with")
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: original).matches.first)
        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [match.rect]], keepSearchable: true, to: output)

        let copy = try RedactPDF.open(output)
        for key in ["Title", "Author", "Subject", "Keywords"] { XCTAssertNil(copy.documentAttributes?[key], key) }
        let raw = try Data(contentsOf: output)
        XCTAssertNil(raw.range(of: Data("Jane Metadata".utf8)))
        XCTAssertNil(raw.range(of: Data("Quarterly Secret Report".utf8)))
    }

    func testTheOriginalIsNeverReplacedOrChanged() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let before = try Data(contentsOf: source)
        XCTAssertThrowsError(try RedactPDF.export(source: source, regions: [0: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)]],
                                                  keepSearchable: false, to: source)) { error in
            XCTAssertEqual(error as? RedactPDFError, .wouldOverwrite)
        }
        XCTAssertEqual(try Data(contentsOf: source), before)

        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)]], keepSearchable: false, to: output)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    func testExportingReplacesAnExistingCopyAndLeavesNoStrayFiles() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let output = dir.appendingPathComponent("out.pdf")
        try Data("old".utf8).write(to: output)
        _ = try RedactPDF.export(source: source, regions: [0: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)]], keepSearchable: false, to: output)
        XCTAssertNotNil(PDFDocument(url: output))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(Set(names), [source.lastPathComponent, "out.pdf"], "a temporary file was left behind")
    }

    func testNothingToRedactIsAnError() throws {
        let source = try makePDF(pages: [[Line("Hello", x: 72, y: 600, size: 28)]])
        let output = dir.appendingPathComponent("out.pdf")
        XCTAssertThrowsError(try RedactPDF.export(source: source, regions: [:], keepSearchable: false, to: output)) {
            XCTAssertEqual($0 as? RedactPDFError, .nothingToRedact)
        }
        XCTAssertThrowsError(try RedactPDF.export(source: source, regions: [5: [CGRect(x: 0, y: 0, width: 0.5, height: 0.5)]], keepSearchable: false, to: output)) {
            XCTAssertEqual($0 as? RedactPDFError, .nothingToRedact, "a box on a page that does not exist is not a redaction")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: Opening

    func testFilesThatAreNotUsablePDFsAreRefused() throws {
        let text = dir.appendingPathComponent("notes.pdf")
        try Data("not a pdf".utf8).write(to: text)
        XCTAssertThrowsError(try RedactPDF.open(text)) { XCTAssertEqual($0 as? RedactPDFError, .unreadable) }

        let locked = try makePDF(pages: [[Line("Hello", x: 72, y: 600, size: 28)]], password: "pw")
        XCTAssertThrowsError(try RedactPDF.open(locked)) { XCTAssertEqual($0 as? RedactPDFError, .locked) }
    }

    // MARK: Model

    @MainActor func testOpeningAFileReadsItsPagesAndBoxesCanBeAddedMovedAndRemoved() throws {
        let model = RedactPDFModel()
        model.open(try makePDF(pages: [[Line("One", x: 72, y: 600, size: 28)], [Line("Two", x: 72, y: 600, size: 28)]]))
        XCTAssertTrue(model.hasDocument)
        XCTAssertEqual(model.pageCount, 2)
        XCTAssertEqual(model.pageSizes.first, CGSize(width: 612, height: 792))
        XCTAssertEqual(model.currentPage, 0)

        let id = try XCTUnwrap(model.addRegion(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), onPage: 1))
        XCTAssertNil(model.addRegion(CGRect(x: 0, y: 0, width: 0.1, height: 0.1), onPage: 2), "there is no page 3")
        XCTAssertEqual(model.regions.count, 1)
        XCTAssertEqual(model.regions(onPage: 1).count, 1)
        XCTAssertEqual(model.regions(onPage: 0).count, 0)
        XCTAssertEqual(model.selectedRegionID, id)

        model.setRect(CGRect(x: 0.9, y: 0.95, width: 0.5, height: 0.5), of: id)
        let moved = try XCTUnwrap(model.selectedRegion).rect
        XCTAssertEqual(moved.maxX, 1, accuracy: 1e-9, "a box stays on its page")
        XCTAssertEqual(moved.maxY, 1, accuracy: 1e-9)

        model.reveal(id)
        XCTAssertEqual(model.currentPage, 1, "choosing a box in the list brings its page into view")
        model.remove(id)
        XCTAssertTrue(model.regions.isEmpty)
        XCTAssertNil(model.selectedRegionID)
    }

    @MainActor func testAFileThatCannotBeOpenedLeavesTheOpenOneAloneAndSaysWhy() throws {
        let model = RedactPDFModel()
        model.open(try makePDF(pages: [[Line("One", x: 72, y: 600, size: 28)]]))
        _ = model.addRegion(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), onPage: 0)
        let bad = dir.appendingPathComponent("bad.pdf")
        try Data("nope".utf8).write(to: bad)
        model.open(bad)
        XCTAssertEqual(model.notice, RedactPDFError.unreadable.errorDescription)
        XCTAssertEqual(model.regions.count, 1)
        XCTAssertEqual(model.fileName, model.url?.lastPathComponent)
        model.close()
        XCTAssertFalse(model.hasDocument)
        XCTAssertTrue(model.regions.isEmpty)
    }

    @MainActor func testRedactAllCoversEveryMatchOnceAndReportsWhatItDid() async throws {
        let model = RedactPDFModel()
        model.open(try makePDF(pages: [
            [Line("Jane Appleseed", x: 72, y: 700, size: 28), Line("Dear Jane", x: 72, y: 600, size: 28)],
            [Line("jane again", x: 72, y: 600, size: 28)],
        ]))
        model.query = "Jane"
        model.redactAll()
        try await waitUntilDone(model)
        XCTAssertEqual(model.regions.count, 3)
        XCTAssertEqual(model.regions.map(\.page).sorted(), [0, 0, 1])
        XCTAssertTrue(model.regions.allSatisfy { $0.label?.lowercased().contains("jane") ?? false })
        XCTAssertEqual(model.findMessage, "Covered 3 matches on 2 pages.")

        model.redactAll()
        try await waitUntilDone(model)
        XCTAssertEqual(model.regions.count, 3, "searching again does not stack boxes")
        XCTAssertEqual(model.findMessage, "Every match is already covered.")

        model.query = "Zebra"
        model.redactAll()
        try await waitUntilDone(model)
        XCTAssertEqual(model.findMessage, "No matches for “Zebra”.")
    }

    @MainActor func testChangingTheBoxesForgetsTheLastSavedFile() throws {
        let model = RedactPDFModel()
        model.open(try makePDF(pages: [[Line("One", x: 72, y: 600, size: 28)]]))
        let id = try XCTUnwrap(model.addRegion(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), onPage: 0))
        XCTAssertNil(model.saved)
        model.keepSearchable = false
        model.keepSearchable = true
        model.remove(id)
        XCTAssertNil(model.saved)
    }

    func testSummariesAreWorded() {
        XCTAssertEqual(RedactPDFModel.summary(matches: 0, added: 0, pages: 0, scanned: 0, text: "x"), "No matches for “x”.")
        XCTAssertEqual(RedactPDFModel.summary(matches: 1, added: 1, pages: 1, scanned: 0, text: "x"), "Covered 1 match on 1 page.")
        XCTAssertEqual(RedactPDFModel.summary(matches: 2, added: 2, pages: 2, scanned: 1, text: "x"),
                       "Covered 2 matches on 2 pages. 1 scanned page was read, which can miss words, so check it.")
        XCTAssertTrue(RedactPDFModel.summary(matches: 0, added: 0, pages: 0, scanned: 3, text: "x").hasSuffix("3 scanned pages were read, which can miss words, so check them."))
    }

    // MARK: Helpers

    private struct Line {
        let text: String, x: CGFloat, y: CGFloat, size: CGFloat
        init(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) { (self.text, self.x, self.y, self.size) = (text, x, y, size) }
    }

    /// A letter-size PDF whose pages have `lines` printed as real text. `crop` and `rotation` apply to the first page.
    private func makePDF(pages: [[Line]], rotation: Int = 0, crop: CGRect? = nil, title: String? = nil, author: String? = nil,
                         password: String? = nil) throws -> URL {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [:]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        if let password { info[kCGPDFContextUserPassword] = password; info[kCGPDFContextOwnerPassword] = password }
        let pdf = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &media, info as CFDictionary))
        for lines in pages {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(gray: 0, alpha: 1)
            for line in lines {
                let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
                let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [
                    .font: font, .foregroundColor: NSColor.black]))
                pdf.textPosition = CGPoint(x: line.x, y: line.y)
                CTLineDraw(text, pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
        if rotation != 0 || crop != nil {
            let document = try XCTUnwrap(PDFDocument(data: data as Data))
            let page = try XCTUnwrap(document.page(at: 0))
            page.rotation = rotation
            if let crop { page.setBounds(crop, for: .cropBox) }
            let url = dir.appendingPathComponent("source-\(UUID()).pdf")
            XCTAssertTrue(document.write(to: url))
            return url
        }
        let url = dir.appendingPathComponent("source-\(UUID()).pdf")
        try (data as Data).write(to: url)
        return url
    }

    /// A one-page PDF that is only a picture of `text`, with no text layer.
    private func makeScannedPDF(text: String, size: CGFloat) throws -> URL {
        let (w, h) = (1224, 1584)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, size * 2, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        bitmap.textPosition = CGPoint(x: 160, y: 900)
        CTLineDraw(line, bitmap)
        let picture = try XCTUnwrap(bitmap.makeImage())

        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &media, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(picture, in: media)
        pdf.endPDFPage()
        pdf.closePDF()
        let url = dir.appendingPathComponent("scan-\(UUID()).pdf")
        try (data as Data).write(to: url)
        return url
    }

    /// The page at one pixel per point.
    private func render(_ document: PDFDocument, page: Int) throws -> CGImage {
        let page = try XCTUnwrap(document.page(at: page))
        return try XCTUnwrap(RedactPDF.render(page, pixelWidth: Int(RedactPDF.uprightSize(of: page).width)))
    }

    private func darkPixels(_ image: CGImage) throws -> [(x: Int, y: Int)] {
        let bytes = try XCTUnwrap(CFDataGetBytePtr(try XCTUnwrap(image.dataProvider?.data)))
        var out: [(Int, Int)] = []
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4] < 128 { out.append((x, y)) }
        }
        return out
    }

    /// The box around everything dark on the page, normalized with the origin at the top left.
    private func inkBounds(of image: CGImage) throws -> CGRect {
        let dark = try darkPixels(image)
        let first = try XCTUnwrap(dark.first, "the page is blank")
        var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
        for p in dark { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        return CGRect(x: CGFloat(minX) / w, y: CGFloat(minY) / h, width: CGFloat(maxX - minX + 1) / w, height: CGFloat(maxY - minY + 1) / h)
    }

    private func inkCount(_ image: CGImage, in rect: CGRect) throws -> Int {
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        let area = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h)
        return try darkPixels(image).filter { area.contains(CGPoint(x: $0.x, y: $0.y)) }.count
    }

    @MainActor private func waitUntilDone(_ model: RedactPDFModel) async throws {
        for _ in 0..<400 where model.isFinding { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(model.isFinding, "the search never finished")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
