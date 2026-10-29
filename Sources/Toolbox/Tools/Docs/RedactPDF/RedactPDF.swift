import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum RedactPDFError: LocalizedError {
    case unreadable
    case locked
    case empty
    case wouldOverwrite
    case nothingToRedact
    case pageFailed
    case saveFailed
    case notClean

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file is not a PDF macOS can read."
        case .locked: "This PDF is password-protected. Remove the password first, then open it here."
        case .empty: "This PDF has no pages."
        case .wouldOverwrite: "That would replace the original. Choose another name; the original is never changed."
        case .nothingToRedact: "There is nothing to redact yet."
        case .pageFailed: "A page could not be redacted, so no copy was saved."
        case .saveFailed: "The redacted PDF could not be saved."
        case .notClean: "The saved copy still held text from a redacted page, so it was not kept."
        }
    }
}

/// A word or phrase found on a page.
struct RedactPDFMatch: Equatable {
    let page: Int
    /// Normalized to the upright page, origin at the top left, padded a little so the descenders are covered too.
    let rect: CGRect
    let text: String
}

struct RedactPDFFind: Equatable {
    var matches: [RedactPDFMatch]
    /// Pages with no text layer, which were read by Vision instead.
    var scannedPages: Int
}

struct RedactPDFResult: Equatable {
    let url: URL
    let bytes: Int64
    let pages: Int
    /// Pages that were turned into images.
    let redactedPages: Int
}

/// Redacts a PDF for good: every page with a box on it is drawn as a picture with the boxes painted in, so the text
/// under them no longer exists, and the other pages are copied across as they are. All on this Mac, no UI state in here.
///
/// Boxes are rectangles normalized to the upright page (0 to 1 on both sides) with the origin at the top left, which is how
/// the page view draws them (`RedactImage` has the geometry for dragging them). PDFKit counts in points from the bottom
/// left of the unrotated page; the conversion happens in here.
enum RedactPDF {
    /// Pixels per point on export: 200 dpi.
    static let exportScale: CGFloat = 200.0 / 72.0
    /// No exported page picture is larger than this on its longer side.
    static let exportMaxPixel: CGFloat = 4500
    /// The longer side of a page picture Vision reads when searching a page that has no text.
    static let readingPixel: CGFloat = 3000

    // MARK: Opening

    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw RedactPDFError.unreadable }
        guard !document.isLocked else { throw RedactPDFError.locked }
        guard document.pageCount > 0 else { throw RedactPDFError.empty }
        return document
    }

    // MARK: Geometry

    /// The page as it is shown, in points: the crop box, with its sides swapped for a page turned sideways.
    static func uprightSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).standardized
        return ((page.rotation % 360) + 360) % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// `rect` (PDFKit page space) as a normalized box on the upright page.
    static func normalized(_ rect: CGRect, on page: PDFPage) -> CGRect {
        let size = uprightSize(of: page)
        guard size.width > 0, size.height > 0 else { return .zero }
        let upright = rect.applying(page.transform(for: .cropBox)).standardized
        return CGRect(x: upright.minX / size.width, y: 1 - upright.maxY / size.height,
                      width: upright.width / size.width, height: upright.height / size.height)
    }

    /// A found word grown a hair, so the box covers the whole glyphs, then kept inside the page.
    private static func padded(_ rect: CGRect, pageSize: CGSize) -> CGRect {
        RedactImage.fitted(rect.insetBy(dx: -1.5 / pageSize.width, dy: -rect.height * 0.12))
    }

    // MARK: Rendering

    /// The page as an upright picture `pixelWidth` wide, on white.
    static func render(_ page: PDFPage, pixelWidth: Int) -> CGImage? {
        let size = uprightSize(of: page)
        guard size.width > 0, size.height > 0, pixelWidth > 0 else { return nil }
        let height = max(1, Int((CGFloat(pixelWidth) * size.height / size.width).rounded()))
        guard let context = CGContext(data: nil, width: pixelWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(height) / size.height)
        // Draws the page as it is shown, turned the right way up, with its annotations and form entries.
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    // MARK: Finding

    /// Every place `query` is printed, on every page. Pages that have a text layer are searched by PDFKit; pages that are
    /// only a picture of text are read with Vision.
    static func find(_ query: String, in document: PDFDocument) -> RedactPDFFind {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = RedactPDFFind(matches: [], scannedPages: 0)
        guard !needle.isEmpty else { return result }

        for selection in document.findString(needle, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
            // A phrase that runs over two lines becomes one box per line.
            for line in selection.selectionsByLine() {
                guard let page = line.pages.first else { continue }
                let index = document.index(for: page)
                let bounds = line.bounds(for: page)
                guard index != NSNotFound, bounds.width > 0, bounds.height > 0 else { continue }
                let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result.matches.append(RedactPDFMatch(page: index, rect: padded(normalized(bounds, on: page), pageSize: uprightSize(of: page)),
                                                     text: text.isEmpty ? needle : text))
            }
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), !hasText(page) else { continue }
            result.scannedPages += 1
            result.matches += read(page, at: index, for: needle)
        }
        return result
    }

    static func hasText(_ page: PDFPage) -> Bool {
        !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The matches on a page that has no text layer, found by reading its picture.
    private static func read(_ page: PDFPage, at index: Int, for needle: String) -> [RedactPDFMatch] {
        let size = uprightSize(of: page)
        let scale = readingPixel / max(size.width, size.height)
        guard let image = render(page, pixelWidth: max(1, Int(size.width * scale))) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Names, emails and numbers are not words; "correcting" them would hide the wrong thing.
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }

        var found: [RedactPDFMatch] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            var rest = text.startIndex..<text.endIndex
            while let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: rest) {
                if let box = try? candidate.boundingBox(for: range) {
                    found.append(RedactPDFMatch(page: index, rect: padded(RedactImage.topLeft(box.boundingBox), pageSize: size), text: String(text[range])))
                }
                rest = range.upperBound..<text.endIndex
            }
        }
        return found
    }

    // MARK: Exporting

    /// Writes a redacted copy of `source` to `destination`. `regions` maps a page number (from 0) to its boxes.
    /// Pages with boxes are flattened to pictures; with `keepSearchable` the text still visible on them is read again and
    /// laid back over each picture, invisibly. The other pages are copied as they are. The copy starts as a new document,
    /// so the original's title, author, outline and other details are not carried over. The original is never touched.
    static func export(source: URL, regions: [Int: [CGRect]], keepSearchable: Bool, to destination: URL,
                       progress: (Int) -> Void = { _ in }) throws -> RedactPDFResult {
        guard BatchFiles.identity(source) != BatchFiles.identity(destination) else { throw RedactPDFError.wouldOverwrite }
        let input = try open(source)
        let covered = regions.filter { $0.key >= 0 && $0.key < input.pageCount && !$0.value.isEmpty }
        guard !covered.isEmpty else { throw RedactPDFError.nothingToRedact }

        let output = PDFDocument()
        // A flattened page is only a window onto its own one-page document, which has to outlive the write.
        var owners: [PDFDocument] = []
        for index in 0..<input.pageCount {
            guard let page = input.page(at: index) else { throw RedactPDFError.unreadable }
            if let boxes = covered[index] {
                let flat = try flatten(page, covering: boxes, searchable: keepSearchable)
                owners.append(flat.owner)
                output.insert(flat.page, at: output.pageCount)
            } else {
                guard let copy = page.copy() as? PDFPage else { throw RedactPDFError.saveFailed }
                output.insert(copy, at: output.pageCount)
            }
            progress(index + 1)
        }

        // Written beside the destination and checked first, so a copy that fails the check never lands there.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let written = withExtendedLifetime((input, owners)) { output.write(to: temporary) }
        guard written else { throw RedactPDFError.saveFailed }
        try verify(temporary, pages: input.pageCount, covered: covered, searchable: keepSearchable)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch { throw RedactPDFError.saveFailed }
        let bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return RedactPDFResult(url: destination, bytes: bytes, pages: input.pageCount, redactedPages: covered.count)
    }

    /// `page` as a one-page PDF page that is a picture with `boxes` painted black. Nothing of the page's own content is kept.
    private static func flatten(_ page: PDFPage, covering boxes: [CGRect], searchable: Bool) throws -> (page: PDFPage, owner: PDFDocument) {
        let size = uprightSize(of: page)
        guard size.width > 0, size.height > 0 else { throw RedactPDFError.pageFailed }
        let scale = min(exportScale, exportMaxPixel / max(size.width, size.height))
        let (picture, readable) = try autoreleasepool { () -> (CGImage, CGImage) in
            guard let bitmap = renderCovered(page, boxes: boxes, scale: scale) else { throw RedactPDFError.pageFailed }
            return (embeddable(bitmap) ?? bitmap, bitmap)
        }

        let data = NSMutableData()
        var media = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &media, nil) else { throw RedactPDFError.pageFailed }
        pdf.beginPDFPage(nil)
        pdf.draw(picture, in: media)
        // Read from the picture with the boxes already in it, so what they hide cannot come back as text.
        if searchable { DocumentScanner.drawInvisibleText(DocumentScanner.recognizeText(in: readable), in: media, context: pdf) }
        pdf.endPDFPage()
        pdf.closePDF()
        guard let owner = PDFDocument(data: data as Data), let flat = owner.page(at: 0) else { throw RedactPDFError.pageFailed }
        return (flat, owner)
    }

    /// The page at `scale` pixels per point with every box painted solid black over its pixels.
    private static func renderCovered(_ page: PDFPage, boxes: [CGRect], scale: CGFloat) -> CGImage? {
        let size = uprightSize(of: page)
        let width = max(1, Int((size.width * scale).rounded()))
        guard let plain = render(page, pixelWidth: width) else { return nil }
        guard let context = CGContext(data: nil, width: plain.width, height: plain.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let (w, h) = (CGFloat(plain.width), CGFloat(plain.height))
        context.draw(plain, in: CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for box in boxes {
            // Rounded outward, so no half-covered pixel at the edge keeps a trace of what was there.
            context.fill(CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h).integral)
        }
        return context.makeImage()
    }

    /// The picture as JPEG, which the PDF keeps byte for byte. Nil when it could not be encoded.
    private static func embeddable(_ bitmap: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, bitmap, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Checking the copy

    /// The saved copy has to look redacted: all its pages, a black box where each one was, no text on a page that is meant to
    /// have none, and none of the details a document usually carries.
    private static func verify(_ url: URL, pages: Int, covered: [Int: [CGRect]], searchable: Bool) throws {
        guard let copy = PDFDocument(url: url), copy.pageCount == pages else { throw RedactPDFError.saveFailed }
        let attributes = copy.documentAttributes ?? [:]
        for key in ["Title", "Author", "Subject", "Keywords"] where attributes[key] != nil { throw RedactPDFError.notClean }
        for (index, boxes) in covered {
            guard let page = copy.page(at: index), let picture = render(page, pixelWidth: 800) else { throw RedactPDFError.saveFailed }
            if !searchable, hasText(page) { throw RedactPDFError.notClean }
            for box in boxes where !isBlack(picture, at: CGPoint(x: box.midX, y: box.midY)) { throw RedactPDFError.saveFailed }
        }
    }

    /// Whether the pixel at the normalized point (origin top left) is black.
    static func isBlack(_ image: CGImage, at point: CGPoint) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data), image.bitsPerPixel == 32 else { return false }
        let x = min(max(Int(point.x * CGFloat(image.width)), 0), image.width - 1)
        let y = min(max(Int(point.y * CGFloat(image.height)), 0), image.height - 1)
        let offset = y * image.bytesPerRow + x * 4
        return bytes[offset] < 40 && bytes[offset + 1] < 40 && bytes[offset + 2] < 40
    }
}

/// Draws pages on a thread of its own, from its own copy of the document, so scrolling never waits on the page being searched or saved.
actor PDFPageRenderer {
    private let document: PDFDocument

    init?(url: URL) {
        guard let document = try? RedactPDF.open(url) else { return nil }
        self.document = document
    }

    func image(page index: Int, pixelWidth: Int) -> CGImage? {
        document.page(at: index).flatMap { RedactPDF.render($0, pixelWidth: pixelWidth) }
    }
}
