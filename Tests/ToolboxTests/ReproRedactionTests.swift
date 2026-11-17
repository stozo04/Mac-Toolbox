import AVFoundation
import CoreText
import PDFKit
import XCTest
@testable import Toolbox

final class ReproRedactionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("repro-redaction-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let anyBox = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)

    func testR1ExportToAHardLinkOfTheOriginalIsRefused() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let link = dir.appendingPathComponent("link.pdf")
        try FileManager.default.linkItem(at: source, to: link)
        XCTAssertEqual(try inode(source), try inode(link), "precondition: the link and the original are one file")

        XCTAssertThrowsError(try RedactPDF.export(source: source, regions: [0: [anyBox]], keepSearchable: false, to: link),
                             "finding: a hard link to the original was accepted as the destination") { error in
            XCTAssertEqual(error as? RedactPDFError, .wouldOverwrite)
        }
    }

    func testR1ExportToAHardLinkLeavesTheOriginalsBytesAlone() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let link = dir.appendingPathComponent("link.pdf")
        try FileManager.default.linkItem(at: source, to: link)
        let before = try Data(contentsOf: source)

        _ = try? RedactPDF.export(source: source, regions: [0: [anyBox]], keepSearchable: false, to: link)

        XCTAssertEqual(try Data(contentsOf: source), before, "finding: the original's bytes changed")
    }

    func testR1ExportToAHardLinkLeavesTheLinkedNameAlone() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let link = dir.appendingPathComponent("link.pdf")
        try FileManager.default.linkItem(at: source, to: link)
        let before = try Data(contentsOf: source)

        _ = try? RedactPDF.export(source: source, regions: [0: [anyBox]], keepSearchable: false, to: link)

        XCTAssertEqual(try Data(contentsOf: link), before, "finding: the user's other name for the original now holds different bytes")
    }

    func testR2aAScannedPageWithAStampedPageNumberIsStillRead() throws {
        let plain = try RedactPDF.open(try makeScannedPDF(text: "Appleseed", size: 64, stamp: nil))
        let plainFind = RedactPDF.find("Appleseed", in: plain)
        XCTAssertEqual(plainFind.scannedPages, 1, "precondition: the picture-only page is read by Vision")
        XCTAssertFalse(plainFind.matches.isEmpty, "precondition: Vision can read the word in the picture")

        let stamped = try RedactPDF.open(try makeScannedPDF(text: "Appleseed", size: 64, stamp: "1"))
        let page = try XCTUnwrap(stamped.page(at: 0))
        XCTAssertTrue(RedactPDF.hasText(page), "precondition: the stamped page has a text layer")
        XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), "1", "precondition: the text layer is only the page number")

        let found = RedactPDF.find("Appleseed", in: stamped)
        XCTAssertEqual(found.scannedPages, 1, "finding: the page was not read by Vision because it has a text layer")
        XCTAssertFalse(found.matches.isEmpty, "finding: the word shown in the picture was not found")
    }

    func testR2cFindSeesAWordShownOnlyInAnAnnotation() throws {
        let source = try makeAnnotatedPDF(secret: "Zanzibar")
        let document = try RedactPDF.open(source)
        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertTrue(page.annotations.contains { ($0.contents ?? "").contains("Zanzibar") }, "precondition: the annotation was saved with the file")
        XCTAssertTrue(RedactPDF.hasText(page), "precondition: the page has its own text")
        let picture = try XCTUnwrap(RedactPDF.render(page, pixelWidth: 612))
        XCTAssertGreaterThan(try darkPixels(picture, rows: 432..<492), 30, "precondition: the annotation's words are drawn on the page")

        let control = RedactPDF.find("Zanzibar", in: try RedactPDF.open(try makeAnnotatedPDF(secret: "Zanzibar", pageText: nil)))
        XCTAssertFalse(control.matches.isEmpty, "precondition: on a page with no text of its own, Vision reads the annotation's words")

        let found = RedactPDF.find("Zanzibar", in: document)
        XCTAssertFalse(found.matches.isEmpty, "finding: a word shown on the page by an annotation was not found")
    }

    func testR2cAnAnnotationOnAPageWithoutBoxesIsCopiedWithItsWords() throws {
        let source = try makeAnnotatedPDF(secret: "Zanzibar")
        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [anyBox]], keepSearchable: false, to: output)

        let copy = try RedactPDF.open(output)
        let page = try XCTUnwrap(copy.page(at: 1))
        XCTAssertTrue(page.annotations.contains { ($0.contents ?? "").contains("Zanzibar") },
                      "observation: the page without boxes is documented as copied as it is, annotations included")
    }

    func testR2cAnAnnotationOnAPageWithABoxIsGoneFromTheCopy() throws {
        let source = try makeAnnotatedPDF(secret: "Zanzibar")
        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [1: [anyBox]], keepSearchable: false, to: output)

        let copy = try RedactPDF.open(output)
        let page = try XCTUnwrap(copy.page(at: 1))
        XCTAssertFalse(page.annotations.contains { ($0.contents ?? "").contains("Zanzibar") }, "finding: the annotation survived on a flattened page")
        XCTAssertNil(try Data(contentsOf: output).range(of: Data("Zanzibar".utf8)), "finding: the annotation's words are still in the file")
    }

    func testR2cExportRefusesACopyThatStillHoldsAnUncoveredMatch() throws {
        for searchable in [false, true] {
            let source = try makePDF(pages: [[Line("Appleseed first", x: 72, y: 700, size: 40), Line("Appleseed second", x: 72, y: 500, size: 40)]])
            let matches = RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches
            XCTAssertEqual(matches.count, 2, "precondition: both lines are found")
            let first = try XCTUnwrap(matches.first)
            let output = dir.appendingPathComponent("partial-\(searchable).pdf")
            _ = try RedactPDF.export(source: source, regions: [0: [first.rect]], keepSearchable: searchable, to: output)

            let after = RedactPDF.find("Appleseed", in: try RedactPDF.open(output))
            XCTAssertTrue(after.matches.isEmpty,
                          "finding (searchable \(searchable)): the copy was kept although searching it still finds the word \(after.matches.count) time(s), pages read by Vision: \(after.scannedPages)")
        }
    }

    func testR2cAMatchOnAnotherPageSurvivesAsRealText() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)], [Line("Appleseed again", x: 72, y: 600, size: 28)]])
        let matches = RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches
        let first = try XCTUnwrap(matches.first { $0.page == 0 })
        let output = dir.appendingPathComponent("out.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [first.rect]], keepSearchable: false, to: output)

        let copy = try RedactPDF.open(output)
        XCTAssertFalse((copy.string ?? "").contains("Appleseed"), "finding: the copy passed its check with the word still in its text")
    }

    func testR2cAWordHalfUnderABoxCannotBeFoundInTheCopy() throws {
        for searchable in [false, true] {
            let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 40)]])
            let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first)
            let half = CGRect(x: match.rect.minX, y: match.rect.minY, width: match.rect.width / 2, height: match.rect.height)
            let output = dir.appendingPathComponent("half-\(searchable).pdf")
            _ = try RedactPDF.export(source: source, regions: [0: [half]], keepSearchable: searchable, to: output)

            let copy = try RedactPDF.open(output)
            XCTAssertTrue(RedactPDF.find("Appleseed", in: copy).matches.isEmpty, "finding (searchable \(searchable)): the half-covered word is still found")
            XCTAssertFalse((copy.string ?? "").localizedCaseInsensitiveContains("Appleseed"), "finding (searchable \(searchable)): the word is still in the text")
        }
    }

    func testR5CleanDropsTheQueryStringOfALink() {
        let cleaned = LogText.clean("ERROR: Unsupported URL: https://example.com/watch?v=1&sig=SECRETTOKEN", limit: 400)
        XCTAssertFalse(cleaned.contains("SECRETTOKEN"), "finding: the query string reached the log text: \(cleaned)")
    }

    func testR5DetailsOfAYtDlpFailureCarryNoQueryString() {
        let stderr = "WARNING: something\nERROR: Unsupported URL: https://example.com/watch?v=1&sig=SECRETTOKEN\n"
        let error = DownloadError.failed(YtDlpCommand.friendlyError(from: stderr))
        XCTAssertTrue(error.localizedDescription.contains("SECRETTOKEN"), "precondition: the message shown to the user keeps yt-dlp's wording")

        let details = Log.details(error, ["url": LogText.safeURL(URL(fileURLWithPath: "/dev/null"))])
        for (key, value) in details.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(value.contains("SECRETTOKEN"), "finding: \(key) carries the query string: \(value)")
        }
        let fitted = LogEvent(timestamp: Date(), level: .error, category: "download", message: "Download failed", metadata: details,
                              appVersion: "1", osVersion: "os", installID: "i", sessionID: "s").fitted()
        for (key, value) in fitted.metadata.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(value.contains("SECRETTOKEN"), "finding: after fitting, \(key) still carries the query string")
        }
    }

    func testR6OutputFolderThatCannotBeMadeIsNotHandedBackAsIfItExisted() {
        let impossible = String(repeating: "x", count: 300)
        let folder = BatchFiles.makeOutputFolder(named: impossible)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
        XCTAssertTrue(exists && isDirectory.boolValue, "finding: a folder that was never made was returned with no error: name of \(folder.lastPathComponent.utf8.count) bytes")
    }

    func testR6TrimmingTheSameFileTwiceKeepsTheFirstClip() async throws {
        let source = dir.appendingPathComponent("clip.mov")
        try await makeClip(at: source, seconds: 4)
        let out = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let first = try await VideoTrimmer.trim(source: source, start: 1, end: 3, into: out) { _ in }
        let firstBytes = try Data(contentsOf: first.url)
        XCTAssertFalse(first.reencoded, "precondition: the first trim is a plain copy")
        let second = try await VideoTrimmer.trim(source: source, start: 0, end: 1, into: out) { _ in }

        XCTAssertNotEqual(second.url, first.url, "finding: the second clip was written to the first clip's name")
        XCTAssertFalse(second.reencoded, "finding: the second trim only worked through the fallback, which removes the file in its way")
        let firstNow = try? Data(contentsOf: first.url)
        XCTAssertEqual(firstNow, firstBytes, "finding: the first clip is no longer the file that was saved")
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(files.count, 2, "finding: two trims left \(files.count) file(s): \(files)")
    }

    private struct Line {
        let text: String, x: CGFloat, y: CGFloat, size: CGFloat
        init(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) { (self.text, self.x, self.y, self.size) = (text, x, y, size) }
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let number = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)
        return number.uint64Value
    }

    private func darkPixels(_ image: CGImage, rows: Range<Int>) throws -> Int {
        let bytes = try XCTUnwrap(CFDataGetBytePtr(try XCTUnwrap(image.dataProvider?.data)))
        var count = 0
        for y in rows.clamped(to: 0..<image.height) {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x * 4] < 128 { count += 1 }
        }
        return count
    }

    private func draw(_ line: Line, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
        let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: line.x, y: line.y)
        CTLineDraw(text, context)
    }

    private func pdfData(_ pages: [(CGContext) -> Void]) throws -> Data {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &media, nil))
        for page in pages {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(gray: 0, alpha: 1)
            page(pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }

    private func makePDF(pages: [[Line]]) throws -> URL {
        let data = try pdfData(pages.map { lines in { context in lines.forEach { self.draw($0, in: context) } } })
        let url = dir.appendingPathComponent("source-\(UUID()).pdf")
        try data.write(to: url)
        return url
    }

    private func makeScannedPDF(text: String, size: CGFloat, stamp: String?) throws -> URL {
        let (w, h) = (1224, 1584)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(Line(text, x: 160, y: 900, size: size * 2), in: bitmap)
        let picture = try XCTUnwrap(bitmap.makeImage())

        let data = try pdfData([{ context in
            context.draw(picture, in: CGRect(x: 0, y: 0, width: 612, height: 792))
            if let stamp { self.draw(Line(stamp, x: 300, y: 30, size: 10), in: context) }
        }])
        let url = dir.appendingPathComponent("scan-\(UUID()).pdf")
        try data.write(to: url)
        return url
    }

    private func makeAnnotatedPDF(secret: String, pageText: String? = "Second page text") throws -> URL {
        let data = try pdfData([
            { context in self.draw(Line("Jane Appleseed", x: 72, y: 600, size: 28), in: context) },
            { context in if let pageText { self.draw(Line(pageText, x: 72, y: 600, size: 28), in: context) } },
        ])
        let document = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(document.page(at: 1))
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 400, height: 60), forType: .freeText, withProperties: nil)
        note.contents = secret
        note.font = NSFont(name: "Helvetica", size: 36)
        note.fontColor = .black
        note.color = .white
        page.addAnnotation(note)
        let url = dir.appendingPathComponent("annotated-\(UUID()).pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func makeClip(at url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 5 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
