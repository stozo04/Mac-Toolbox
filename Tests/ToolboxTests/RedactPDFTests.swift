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

    func testFindReadsAScannedPageThatAlsoHasAStampedPageNumber() throws {
        let document = try RedactPDF.open(try makeScannedPDF(text: "Appleseed", size: 64, stamp: "1"))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), "1", "the test page's text layer must be only the page number")

        let found = RedactPDF.find("Appleseed", in: document)
        XCTAssertEqual(found.scannedPages, 1)
        XCTAssertEqual(found.matches.count, 1)
        XCTAssertEqual(found.unreadablePages, [])
    }

    func testFindSeesAWordShownOnlyByANote() throws {
        let document = try RedactPDF.open(try makeAnnotatedPDF(note: "Zanzibar"))
        XCTAssertTrue(RedactPDF.hasText(try XCTUnwrap(document.page(at: 1))), "the test page must have text of its own")

        let found = RedactPDF.find("Zanzibar", in: document)
        XCTAssertEqual(found.matches.map(\.page), [1])
        XCTAssertEqual(found.scannedPages, 1, "only the page with the note needs reading")
    }

    func testAWordInTheTextLayerOfAPageThatIsAlsoReadGetsOneBox() throws {
        let document = try RedactPDF.open(try makeAnnotatedPDF(note: "Zanzibar"))
        let found = RedactPDF.find("Second page", in: document)
        XCTAssertEqual(found.scannedPages, 1)
        XCTAssertEqual(found.matches.count, 1, "the same words were boxed once from the text and once from the picture")
    }

    func testOnlyPagesWhosePictureCanShowMoreThanTheirTextAreRead() throws {
        let scribble = { (context: CGContext) in
            context.move(to: CGPoint(x: 100, y: 100))
            context.addCurve(to: CGPoint(x: 300, y: 100), control1: CGPoint(x: 150, y: 200), control2: CGPoint(x: 250, y: 0))
            context.strokePath()
        }
        let ruledTable = { (context: CGContext) in
            context.stroke(CGRect(x: 72, y: 500, width: 400, height: 100))
            context.move(to: CGPoint(x: 72, y: 550))
            context.addLine(to: CGPoint(x: 472, y: 550))
            context.strokePath()
        }
        let document = try RedactPDF.open(try makeDrawnPDF(pages: [{ _ in }, ruledTable, scribble]))
        let reads = try (0..<3).map { RedactPDF.mayShowMoreThanItsText(try XCTUnwrap(document.page(at: $0))) }
        XCTAssertEqual(reads, [false, false, true], "text only, text with straight rules, text with a curve")

        let scan = try RedactPDF.open(try makeScannedPDF(text: "Appleseed", size: 64, stamp: "1"))
        XCTAssertTrue(RedactPDF.mayShowMoreThanItsText(try XCTUnwrap(scan.page(at: 0))))
    }

    func testAPageWithAnInlineImageIsRead() throws {
        let text = "BT /F1 14 Tf 72 700 Td (A page of ordinary words that PDFKit can search) Tj ET"
        let inlineImage = " q 40 0 0 40 100 100 cm BI /W 1 /H 1 /CS /G /BPC 8 ID \u{7F} EI Q"
        let plain = try RedactPDF.open(try writeHandMadePDF(content: text))
        let withImage = try RedactPDF.open(try writeHandMadePDF(content: text + inlineImage))

        XCTAssertTrue(RedactPDF.hasText(try XCTUnwrap(plain.page(at: 0))), "the hand-made page must have a text layer")
        XCTAssertFalse(RedactPDF.mayShowMoreThanItsText(try XCTUnwrap(plain.page(at: 0))))
        XCTAssertTrue(RedactPDF.mayShowMoreThanItsText(try XCTUnwrap(withImage.page(at: 0))))
    }

    func testAPageThatCannotBeReadIsReportedAndItsTextLayerIsStillSearched() throws {
        struct VisionIsDown: Error {}
        let document = try RedactPDF.open(try makeAnnotatedPDF(note: "Zanzibar"))

        let found = RedactPDF.find("Second page", in: document) { _ in throw VisionIsDown() }
        XCTAssertEqual(found.unreadablePages, [1])
        XCTAssertEqual(found.scannedPages, 0)
        XCTAssertEqual(found.matches.count, 1)

        let note = RedactPDF.find("Zanzibar", in: document) { _ in throw VisionIsDown() }
        XCTAssertEqual(note.unreadablePages, [1])
        XCTAssertTrue(note.matches.isEmpty)
    }

    func testReadingFailuresAreLoggedOnceWithTheReason() throws {
        struct VisionIsDown: Error {}
        let sink = MemorySink(minimumLevel: .warning)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        let scans = try RedactPDF.open(try makeDrawnPDF(pages: [{ $0.fillEllipse(in: CGRect(x: 9, y: 9, width: 9, height: 9)) },
                                                                { $0.fillEllipse(in: CGRect(x: 9, y: 9, width: 9, height: 9)) }]))

        XCTAssertEqual(RedactPDF.find("Anything", in: scans) { _ in throw VisionIsDown() }.unreadablePages, [0, 1])
        let event = try XCTUnwrap(sink.events.first { $0.message == "Pages could not be read" })
        XCTAssertEqual(sink.events.filter { $0.message == "Pages could not be read" }.count, 1)
        XCTAssertEqual(event.metadata["unreadable"], "2")
        XCTAssertEqual(event.metadata["first_page"], "1")
        XCTAssertTrue(event.metadata["error_type"]?.contains("VisionIsDown") ?? false)
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

    func testAnotherNameForTheOriginalIsRefusedAsTheDestination() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let before = try Data(contentsOf: source)
        let hardLink = dir.appendingPathComponent("hard-link.pdf")
        try FileManager.default.linkItem(at: source, to: hardLink)
        let symbolicLink = dir.appendingPathComponent("symbolic-link.pdf")
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: source)

        for destination in [hardLink, symbolicLink] {
            XCTAssertTrue(BatchFiles.isSameFile(source, destination), destination.lastPathComponent)
            XCTAssertThrowsError(try RedactPDF.export(source: source, regions: [0: [CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)]],
                                                      keepSearchable: false, to: destination), destination.lastPathComponent) { error in
                XCTAssertEqual(error as? RedactPDFError, .wouldOverwrite)
            }
            XCTAssertEqual(try Data(contentsOf: source), before, "the original changed through \(destination.lastPathComponent)")
            XCTAssertEqual(try Data(contentsOf: destination), before, "\(destination.lastPathComponent) no longer holds the original")
        }
    }

    func testDifferentFilesWithTheSameBytesAreNotTheSameFile() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]])
        let twin = dir.appendingPathComponent("twin.pdf")
        try FileManager.default.copyItem(at: source, to: twin)
        XCTAssertFalse(BatchFiles.isSameFile(source, twin))
        XCTAssertFalse(BatchFiles.isSameFile(source, dir.appendingPathComponent("not-there.pdf")))
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

    func testAMatchLeftUncoveredOnPurposeStillExportsAndIsCounted() throws {
        for searchable in [false, true] {
            let source = try makePDF(pages: [[Line("Appleseed first", x: 72, y: 700, size: 40), Line("Appleseed second", x: 72, y: 500, size: 40)],
                                             [Line("Appleseed again", x: 72, y: 600, size: 28)]])
            let first = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first { $0.page == 0 })
            let output = dir.appendingPathComponent("partial-\(searchable).pdf")

            let result = try RedactPDF.export(source: source, regions: [0: [first.rect]], keepSearchable: searchable, to: output,
                                              searchedFor: ["Appleseed", " appleseed ", "Zebra"])
            XCTAssertEqual(result.leftUncovered, [RedactPDFLeftover(query: "Appleseed", matches: 2)], "searchable \(searchable)")
            XCTAssertNotNil(PDFDocument(url: output))
        }
    }

    func testACopyWithEveryMatchCoveredHasNothingLeftToReport() throws {
        let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)], [Line("Appleseed again", x: 72, y: 600, size: 28)]])
        var boxes: [Int: [CGRect]] = [:]
        for match in RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches { boxes[match.page, default: []].append(match.rect) }
        let output = dir.appendingPathComponent("out.pdf")

        let result = try RedactPDF.export(source: source, regions: boxes, keepSearchable: true, to: output, searchedFor: ["Appleseed"])
        XCTAssertEqual(result.leftUncovered, [])
        XCTAssertEqual(try RedactPDF.export(source: source, regions: boxes, keepSearchable: true, to: output).leftUncovered, [])
    }

    func testAMatchStillFoundUnderABoxMeansTheCopyIsNotClean() throws {
        let unredacted = try RedactPDF.open(try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)]]))
        let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: unredacted).matches.first)

        XCTAssertThrowsError(try RedactPDF.uncoveredMatches(of: ["Appleseed"], in: unredacted, covered: [0: [match.rect]])) { error in
            XCTAssertEqual(error as? RedactPDFError, .notClean)
        }
        let besideIt = CGRect(x: match.rect.maxX - 0.002, y: match.rect.minY, width: 0.1, height: match.rect.height)
        XCTAssertEqual(try RedactPDF.uncoveredMatches(of: ["Appleseed"], in: unredacted, covered: [0: [besideIt]]),
                       [RedactPDFLeftover(query: "Appleseed", matches: 1)], "a box that only touches the word does not cover it")
        XCTAssertEqual(try RedactPDF.uncoveredMatches(of: ["Appleseed"], in: unredacted, covered: [1: [match.rect]]),
                       [RedactPDFLeftover(query: "Appleseed", matches: 1)], "a box on another page does not cover it")
    }

    func testAWordHalfUnderABoxCannotBeFoundInTheCopy() throws {
        for searchable in [false, true] {
            let source = try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 40)]])
            let match = try XCTUnwrap(RedactPDF.find("Appleseed", in: try RedactPDF.open(source)).matches.first)
            let half = CGRect(x: match.rect.minX, y: match.rect.minY, width: match.rect.width / 2, height: match.rect.height)
            let output = dir.appendingPathComponent("half-\(searchable).pdf")
            let result = try RedactPDF.export(source: source, regions: [0: [half]], keepSearchable: searchable, to: output, searchedFor: ["Appleseed"])

            XCTAssertEqual(result.leftUncovered, [], "searchable \(searchable)")
            let copy = try RedactPDF.open(output)
            XCTAssertFalse((copy.string ?? "").localizedCaseInsensitiveContains("Appleseed"), "searchable \(searchable): the word is still in the text")
        }
    }

    func testANoteIsKeptOnAPageWithoutBoxesAndGoneFromAPageWithOne() throws {
        let source = try makeAnnotatedPDF(note: "Zanzibar")
        let box = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let holdsTheNote = { (url: URL) throws -> Bool in
            try XCTUnwrap(try RedactPDF.open(url).page(at: 1)).annotations.contains { ($0.contents ?? "").contains("Zanzibar") }
        }

        let otherPageBoxed = dir.appendingPathComponent("other-page.pdf")
        _ = try RedactPDF.export(source: source, regions: [0: [box]], keepSearchable: false, to: otherPageBoxed)
        XCTAssertTrue(try holdsTheNote(otherPageBoxed), "a page without boxes is copied as it is, notes included")

        let notePageBoxed = dir.appendingPathComponent("note-page.pdf")
        _ = try RedactPDF.export(source: source, regions: [1: [box]], keepSearchable: false, to: notePageBoxed)
        XCTAssertFalse(try holdsTheNote(notePageBoxed))
        XCTAssertNil(try Data(contentsOf: notePageBoxed).range(of: Data("Zanzibar".utf8)), "the note's words are still in the file")
    }

    func testASaveFailureKeepsItsWordingAndCarriesTheReasonForTheLog() {
        let reason = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let error = RedactPDFError.saveFailed(underlying: reason)
        XCTAssertEqual(error.localizedDescription, "The redacted PDF could not be saved.")
        XCTAssertEqual(RedactPDFError.saveFailed().localizedDescription, "The redacted PDF could not be saved.")
        XCTAssertTrue(Log.details(error)["underlying"]?.hasPrefix("NSCocoaErrorDomain 513") ?? false)
        XCTAssertNil(Log.details(RedactPDFError.saveFailed())["underlying"])
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

    @MainActor func testExportSaysHowManySearchedMatchesWereLeftUncovered() async throws {
        let model = RedactPDFModel()
        model.open(try makePDF(pages: [
            [Line("Jane Appleseed", x: 72, y: 700, size: 28), Line("Dear Jane", x: 72, y: 500, size: 28)],
            [Line("jane again", x: 72, y: 600, size: 28)],
        ]))
        model.query = " Jane "
        model.redactAll()
        try await waitUntilDone(model)
        model.query = "jane"
        model.redactAll()
        try await waitUntilDone(model)
        XCTAssertEqual(model.redactedQueries, ["Jane"])

        model.export(to: dir.appendingPathComponent("all-covered.pdf"))
        try await waitUntilDone(model)
        XCTAssertNil(model.notice)
        XCTAssertEqual(try XCTUnwrap(model.saved).leftUncovered, [])
        XCTAssertNil(RedactPDFModel.leftUncoveredNote(try XCTUnwrap(model.saved).leftUncovered))

        model.remove(try XCTUnwrap(model.regions.first { $0.page == 1 }).id)
        XCTAssertNil(model.saved)
        model.export(to: dir.appendingPathComponent("one-left.pdf"))
        try await waitUntilDone(model)
        XCTAssertNil(model.notice, "a match left uncovered on purpose is not an error")
        let saved = try XCTUnwrap(model.saved)
        XCTAssertEqual(saved.leftUncovered, [RedactPDFLeftover(query: "Jane", matches: 1)])
        XCTAssertEqual(RedactPDFModel.leftUncoveredNote(saved.leftUncovered), "Still in the copy where it was left uncovered: “Jane” 1 time.")

        model.close()
        XCTAssertEqual(model.redactedQueries, [])
    }

    func testTheLeftUncoveredNoteCountsEachWord() {
        XCTAssertEqual(RedactPDFModel.leftUncoveredNote([RedactPDFLeftover(query: "Jane", matches: 2), RedactPDFLeftover(query: "555", matches: 1)]),
                       "Still in the copy where it was left uncovered: “Jane” 2 times, “555” 1 time.")
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
                       "Covered 2 matches on 2 pages. 1 page has pictures or notes that were read as images, which can miss words, so check it.")
        XCTAssertTrue(RedactPDFModel.summary(matches: 0, added: 0, pages: 0, scanned: 3, text: "x")
            .hasSuffix("3 pages have pictures or notes that were read as images, which can miss words, so check them."))
    }

    func testSummariesNameThePagesThatCouldNotBeSearched() {
        XCTAssertEqual(RedactPDFModel.summary(matches: 0, added: 0, pages: 0, scanned: 0, unreadable: [2], text: "x"),
                       "No matches for “x” on the pages that could be searched. Page 3 could not be searched, so check it yourself.")
        XCTAssertEqual(RedactPDFModel.summary(matches: 1, added: 1, pages: 1, scanned: 0, unreadable: [0, 4, 6], text: "x"),
                       "Covered 1 match on 1 page. Pages 1, 5 and 7 could not be searched, so check them yourself.")
        XCTAssertTrue(RedactPDFModel.summary(matches: 1, added: 0, pages: 0, scanned: 2, unreadable: Array(0..<6), text: "x")
            .hasSuffix("so check them. 6 pages could not be searched, so check them yourself."))
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
    private func makeScannedPDF(text: String, size: CGFloat, stamp: String? = nil) throws -> URL {
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
        if let stamp { draw(Line(stamp, x: 300, y: 30, size: 10), in: pdf) }
        pdf.endPDFPage()
        pdf.closePDF()
        let url = dir.appendingPathComponent("scan-\(UUID()).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func draw(_ line: Line, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, line.size, nil)
        let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: line.x, y: line.y)
        CTLineDraw(text, context)
    }

    private func makeDrawnPDF(pages: [(CGContext) -> Void]) throws -> URL {
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &media, nil))
        for page in pages {
            pdf.beginPDFPage(nil)
            pdf.setFillColor(gray: 0, alpha: 1)
            draw(Line("A page of ordinary words that PDFKit can search", x: 72, y: 700, size: 14), in: pdf)
            page(pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        let url = dir.appendingPathComponent("drawn-\(UUID()).pdf")
        try (data as Data).write(to: url)
        return url
    }

    private func writeHandMadePDF(content: String) throws -> URL {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var file = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (number, body) in objects.enumerated() {
            offsets.append(file.utf8.count)
            file += "\(number + 1) 0 obj\n\(body)\nendobj\n"
        }
        let table = file.utf8.count
        file += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { file += String(format: "%010d 00000 n \n", offset) }
        file += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(table)\n%%EOF\n"
        let url = dir.appendingPathComponent("hand-made-\(UUID()).pdf")
        try Data(file.utf8).write(to: url)
        return url
    }

    private func makeAnnotatedPDF(note text: String) throws -> URL {
        let document = try XCTUnwrap(PDFDocument(url: try makePDF(pages: [[Line("Jane Appleseed", x: 72, y: 600, size: 28)],
                                                                          [Line("Second page text", x: 72, y: 600, size: 28)]])))
        let note = PDFAnnotation(bounds: CGRect(x: 72, y: 300, width: 400, height: 60), forType: .freeText, withProperties: nil)
        note.contents = text
        note.font = NSFont(name: "Helvetica", size: 36)
        note.fontColor = .black
        note.color = .white
        try XCTUnwrap(document.page(at: 1)).addAnnotation(note)
        let url = dir.appendingPathComponent("annotated-\(UUID()).pdf")
        XCTAssertTrue(document.write(to: url))
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
        for _ in 0..<400 where model.isBusy { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(model.isBusy, "the search or export never finished")
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
