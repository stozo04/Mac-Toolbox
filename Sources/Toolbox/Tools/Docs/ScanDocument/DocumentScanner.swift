import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// How the pages are cleaned up before they go into the PDF.
enum ScanLook: String, CaseIterable, Identifiable {
    case color, grayscale, blackAndWhite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .color: "Color"
        case .grayscale: "Grayscale"
        case .blackAndWhite: "Black & White"
        }
    }

    var blurb: String {
        switch self {
        case .color: "Brighter paper and crisper ink, colors kept. Best for receipts with logos or photos."
        case .grayscale: "Shades of gray on an evened-out background. Good for text and handwriting, with a smaller file."
        case .blackAndWhite: "Pure black on white, the smallest files. Best for plain text; photos and stamps lose detail."
        }
    }
}

/// The size of each page in the PDF.
enum ScanPageSize: String, CaseIterable, Identifiable {
    case matchScan, a4, letter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .matchScan: "Match the Scan"
        case .a4: "A4"
        case .letter: "US Letter"
        }
    }

    /// The page in points for a picture of this shape. A4 and Letter turn sideways for a wide picture, and the picture is
    /// fitted inside; "Match the Scan" is the picture's own shape with its longer side the length of an A4 sheet.
    func pageSize(forImage image: CGSize) -> CGSize {
        let wide = image.width > image.height
        let sheet: CGSize
        switch self {
        case .matchScan:
            let scale = 841.89 / max(image.width, image.height, 1)
            return CGSize(width: image.width * scale, height: image.height * scale)
        case .a4: sheet = CGSize(width: 595.28, height: 841.89)
        case .letter: sheet = CGSize(width: 612, height: 792)
        }
        return wide ? CGSize(width: sheet.height, height: sheet.width) : sheet
    }
}

/// The four corners of a page found in a photo. Normalized (0...1) with the origin at the bottom left, the way Vision reports them.
struct PageCorners: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    /// Share of the photo the page covers.
    var area: CGFloat {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        var sum: CGFloat = 0
        for i in points.indices {
            let (a, b) = (points[i], points[(i + 1) % points.count])
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// A page that fills a fifth of the photo or more is believable; anything smaller is more likely a picture frame or a logo.
    var isUsable: Bool { area >= 0.2 }

    /// How far the corners are from those of a rectangle: the average of how many degrees each corner is off a right angle,
    /// measured on the photo itself (`size` in pixels). A sheet photographed at an angle is a little off; a bad guess a lot.
    func skew(in size: CGSize) -> CGFloat {
        let points = [topLeft, topRight, bottomRight, bottomLeft].map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        var total: CGFloat = 0
        for i in points.indices {
            let corner = points[i]
            let (a, b) = (points[(i + 3) % 4], points[(i + 1) % 4])
            let (u, v) = (CGPoint(x: a.x - corner.x, y: a.y - corner.y), CGPoint(x: b.x - corner.x, y: b.y - corner.y))
            let lengths = hypot(u.x, u.y) * hypot(v.x, v.y)
            guard lengths > 0 else { return 90 }
            let cosine = max(-1, min(1, (u.x * v.x + u.y * v.y) / lengths))
            total += abs(acos(cosine) * 180 / .pi - 90)
        }
        return total / 4
    }

    /// The same shape drawn `amount` smaller (0.01 is one percent) around its middle, to keep the edge of the paper out of the picture.
    func shrunk(by amount: CGFloat) -> PageCorners {
        let center = CGPoint(x: (topLeft.x + topRight.x + bottomRight.x + bottomLeft.x) / 4, y: (topLeft.y + topRight.y + bottomRight.y + bottomLeft.y) / 4)
        func pull(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + (p.x - center.x) * (1 - amount), y: center.y + (p.y - center.y) * (1 - amount)) }
        return PageCorners(topLeft: pull(topLeft), topRight: pull(topRight), bottomRight: pull(bottomRight), bottomLeft: pull(bottomLeft))
    }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    fileprivate init(_ observation: VNRectangleObservation) {
        self.init(topLeft: observation.topLeft, topRight: observation.topRight,
                  bottomRight: observation.bottomRight, bottomLeft: observation.bottomLeft)
    }
}

/// A page that has been found and straightened.
struct ScannedPage {
    let image: CGImage
    /// False when no page edges were found and the whole picture is used.
    let foundEdges: Bool
}

/// A page ready to be written: the straightened picture and how far it has been turned.
struct ScanExportPage {
    let image: CGImage
    /// Clockwise quarter turns.
    let turns: Int
}

/// One line of text Vision read on a page.
struct RecognizedLine: Equatable {
    let text: String
    /// Normalized (0...1) with the origin at the bottom left of the page picture.
    let box: CGRect
}

enum ScanError: LocalizedError {
    case unreadable
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .unreadable: "A page could not be prepared."
        case .cannotWrite: "The PDF could not be written."
        }
    }
}

/// Finds a page in a photo, straightens it, cleans it up and writes the pages as a PDF. No UI state in here, so it can be tested alone.
enum DocumentScanner {
    /// Colors stay as they are stored, so brightness and thresholds behave the way they do in any photo editor.
    static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    /// Longest side of a page picture kept while editing.
    static let workingSize: CGFloat = 4096
    /// Longest side of a page picture saved in the PDF: A4 at 300 dpi.
    static let exportSize: CGFloat = 3508

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Reading files

    /// Every page in a file: a photo is one page, a PDF has one per page. A folder gives the pages of everything inside it.
    static func scan(file url: URL) -> [ScannedPage] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if isDirectory.boolValue {
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            let files = (walker?.compactMap { $0 as? URL } ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return files.flatMap { scan(file: $0) }
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
        if type?.conforms(to: .pdf) == true {
            return PDFDocument(url: url).map { scan(pdf: $0) } ?? []
        }
        guard type?.conforms(to: .image) == true, let image = load(url) else { return [] }
        return [scan(photo: image)]
    }

    /// A photo of paper: the page is found, cut out and straightened.
    static func scan(photo: CGImage) -> ScannedPage {
        guard let corners = detectPage(in: photo) else { return ScannedPage(image: photo, foundEdges: false) }
        return ScannedPage(image: straighten(photo, corners: corners), foundEdges: true)
    }

    /// The pages of a PDF, such as a scan an iPhone sends. They are flat already, so they are used as they are.
    static func scan(pdf document: PDFDocument) -> [ScannedPage] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index).flatMap { render($0) }.map { ScannedPage(image: $0, foundEdges: true) }
        }
    }

    /// A photo upright and no bigger than `workingSize`.
    static func load(_ url: URL) -> CGImage? {
        guard let reader = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any]
        let longest = max((properties?[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0, (properties?[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0)
        guard longest > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(reader, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, workingSize),
        ] as CFDictionary)
    }

    private static func render(_ page: PDFPage, dpi: CGFloat = 200) -> CGImage? {
        var bounds = page.bounds(for: .mediaBox)
        if page.rotation % 180 != 0 { bounds.size = CGSize(width: bounds.height, height: bounds.width) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(dpi / 72, workingSize / max(bounds.width, bounds.height))
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: Finding and straightening the page

    /// The page in a photo, or nil when none is clear enough.
    static func detectPage(in image: CGImage) -> PageCorners? {
        let handler = VNImageRequestHandler(cgImage: image)
        let size = CGSize(width: image.width, height: image.height)

        // Vision has two detectors. The page-aware one copes with clutter but can pull a corner in when the paper fades
        // into its surroundings; the rectangle one follows the straight edges closely but can take a smaller shape for the page.
        let segmentation = VNDetectDocumentSegmentationRequest()
        let fromSegmentation = (try? handler.perform([segmentation])) != nil ? segmentation.results?.first.map(PageCorners.init) : nil

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.2
        rectangles.maximumAspectRatio = 1
        rectangles.minimumSize = 0.3
        rectangles.minimumConfidence = 0.5
        rectangles.quadratureTolerance = 30
        rectangles.maximumObservations = 1
        let fromRectangles = (try? handler.perform([rectangles])) != nil ? rectangles.results?.first.map(PageCorners.init) : nil

        guard let preferred = [fromSegmentation, fromRectangles].compactMap({ $0 }).first(where: \.isUsable) else { return nil }
        var best = preferred
        // Take the rectangle detector's answer when the page-aware one is visibly crooked and the two describe the same page.
        if let a = fromSegmentation, a.isUsable, let b = fromRectangles, b.isUsable,
           b.skew(in: size) + 4 < a.skew(in: size), b.area >= a.area * 0.6, b.area <= a.area * 1.5 {
            best = b
        }
        // No corner of a real page is that far from a right angle, so this is a wrong guess.
        return best.skew(in: size) <= 35 ? best : nil
    }

    /// The part of the photo inside `corners`, with its perspective removed so the page is a plain upright rectangle.
    static func straighten(_ image: CGImage, corners: PageCorners) -> CGImage {
        let (w, h) = (CGFloat(image.width), CGFloat(image.height))
        // A page that already fills the photo has nothing to cut away.
        guard corners.area < 0.985 else { return image }
        // Detected edges sit on the paper's border; a hair inside it keeps the desk out of the scan.
        let corners = corners.shrunk(by: 0.007)
        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: image)
        filter.topLeft = point(corners.topLeft).cgPointValue
        filter.topRight = point(corners.topRight).cgPointValue
        filter.bottomRight = point(corners.bottomRight).cgPointValue
        filter.bottomLeft = point(corners.bottomLeft).cgPointValue
        guard let output = filter.outputImage, output.extent.width >= 8, output.extent.height >= 8,
              let straight = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: sRGB) else { return image }
        return straight
    }

    // MARK: Cleaning up

    /// The page as it is saved: turned, cleaned up for `look` and no bigger than `maxPixel` on its longer side.
    static func render(_ page: CGImage, turns: Int, look: ScanLook, maxPixel: CGFloat) -> CIImage {
        var image = CIImage(cgImage: page)
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][((turns % 4) + 4) % 4]
        image = zeroOrigin(image.oriented(orientation))
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxPixel {
            image = zeroOrigin(image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: maxPixel / longest, kCIInputAspectRatioKey: 1]))
        }
        return cleanUp(image, look: look)
    }

    /// `render` as a bitmap: eight-bit gray for the gray looks, RGB for color.
    static func bitmap(_ page: CGImage, turns: Int, look: ScanLook, maxPixel: CGFloat) -> CGImage? {
        let image = render(page, turns: turns, look: look, maxPixel: maxPixel)
        return look == .color
            ? context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
            : context.createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    private static func zeroOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    static func cleanUp(_ image: CIImage, look: ScanLook) -> CIImage {
        switch look {
        case .color:
            // Shadows are lifted gently, so a dark logo does not wash out; paper goes white.
            return normalized(image, floor: 0.5)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.12, kCIInputSaturationKey: 1.05])
        case .grayscale:
            return normalized(gray(image), floor: 0.35)
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.2])
        case .blackAndWhite:
            return normalized(gray(image), floor: 0.35)
                .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.78])
        }
    }

    private static func gray(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
    }

    /// Evens out the light across the page. The paper's own brightness is estimated by smearing the lightest pixels
    /// outward (ink is thin, so it disappears) and blurring; dividing by it turns paper white and lifts shadows.
    /// `floor` is how dark the estimate may get, which stops a large dark area being stretched to white.
    static func normalized(_ image: CIImage, floor: CGFloat) -> CIImage {
        let extent = image.extent
        let longest = max(extent.width, extent.height)
        guard longest >= 64 else { return image }
        // The estimate is smooth, so a small copy is as good as the full picture and far quicker.
        let scale = min(1, 512 / longest)
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let radius = max(2, min(longest, 512) * 0.012)
        let paper = small.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: small.extent)
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: floor, y: floor, z: floor, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        let estimate = paper
            .transformed(by: CGAffineTransform(scaleX: extent.width / small.extent.width, y: extent.height / small.extent.height))
            .clampedToExtent()
            .cropped(to: extent)
        // CIDivideBlendMode divides its background by its input: the photo is the background, the paper estimate the input.
        return estimate.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: extent)
    }

    // MARK: Reading the text

    /// Every line of text Vision can read on the page picture.
    static func recognizeText(in image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { line in
            guard let text = line.topCandidates(1).first?.string, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return RecognizedLine(text: text, box: line.boundingBox)
        }
    }

    // MARK: Writing the PDF

    /// The pages as one PDF. With `searchable`, the text Vision reads is laid over each page where it is printed, invisible,
    /// so the PDF can be searched and its text selected. `progress` is told how many pages are done.
    static func makePDF(pages: [ScanExportPage], look: ScanLook, pageSize: ScanPageSize, searchable: Bool,
                        progress: (Int) -> Void = { _ in }) throws -> Data {
        let data = NSMutableData()
        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &first, [kCGPDFContextCreator: "Toolbox"] as CFDictionary) else { throw ScanError.cannotWrite }

        for (index, page) in pages.enumerated() {
            try autoreleasepool {
                guard let picture = embeddable(page, look: look) else { throw ScanError.unreadable }
                let sheet = pageSize.pageSize(forImage: CGSize(width: picture.image.width, height: picture.image.height))
                var box = CGRect(origin: .zero, size: sheet)
                pdf.beginPDFPage([kCGPDFContextMediaBox: withUnsafeBytes(of: &box) { Data($0) }] as CFDictionary)
                pdf.setFillColor(gray: 1, alpha: 1)
                pdf.fill(box)
                let fit = min(sheet.width / CGFloat(picture.image.width), sheet.height / CGFloat(picture.image.height))
                let size = CGSize(width: CGFloat(picture.image.width) * fit, height: CGFloat(picture.image.height) * fit)
                let rect = CGRect(x: (sheet.width - size.width) / 2, y: (sheet.height - size.height) / 2, width: size.width, height: size.height)
                pdf.draw(picture.image, in: rect)
                if searchable { drawInvisibleText(recognizeText(in: picture.readable), in: rect, context: pdf) }
                pdf.endPDFPage()
            }
            progress(index + 1)
        }
        pdf.closePDF()
        return data as Data
    }

    /// `image` goes into the PDF; `readable` is the same picture for Vision.
    private static func embeddable(_ page: ScanExportPage, look: ScanLook) -> (image: CGImage, readable: CGImage)? {
        guard let bitmap = bitmap(page.image, turns: page.turns, look: look, maxPixel: exportSize) else { return nil }
        // Black and white is saved as it is (it compresses to almost nothing); the other looks go in as JPEG, which the PDF keeps byte for byte.
        guard look != .blackAndWhite else { return (bitmap, bitmap) }
        let quality = look == .color ? 0.8 : 0.75
        guard let jpeg = jpegData(bitmap, quality: quality),
              let provider = CGDataProvider(data: jpeg as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return (bitmap, bitmap) }
        return (image, bitmap)
    }

    private static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Lays each line of `lines` over the spot where it is printed, as text that is never drawn.
    static func drawInvisibleText(_ lines: [RecognizedLine], in rect: CGRect, context pdf: CGContext) {
        pdf.saveGState()
        pdf.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: rect.minX + line.box.minX * rect.width, y: rect.minY + line.box.minY * rect.height,
                             width: line.box.width * rect.width, height: line.box.height * rect.height)
            guard box.width > 0, box.height > 0 else { continue }
            let size = max(1, box.height * 0.8)
            let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
            let text = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(text, nil, nil, nil)
            guard width > 0 else { continue }
            // Stretch the line sideways until it is as wide as the printed line, so selecting it highlights the right words.
            pdf.textMatrix = CGAffineTransform(a: box.width / width, b: 0, c: 0, d: 1, tx: box.minX, ty: box.minY + box.height * 0.2)
            CTLineDraw(text, pdf)
        }
        pdf.restoreGState()
    }
}
