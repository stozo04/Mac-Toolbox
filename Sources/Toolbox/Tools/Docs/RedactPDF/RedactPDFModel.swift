import AppKit
import Observation
import PDFKit

@MainActor @Observable
final class RedactPDFModel {
    /// Shared so the boxes survive switching to another tool and back.
    static let shared = RedactPDFModel()

    struct Region: Identifiable, Equatable {
        let id = UUID()
        let page: Int
        /// Normalized to the upright page, origin at the top left.
        var rect: CGRect
        /// The text this box was made for; nil for a box that was dragged out by hand.
        let label: String?
    }

    struct Saved: Equatable {
        let url: URL
        let bytes: Int64
    }

    static let zoomLevels: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    private static let fitZoom = 2

    private(set) var url: URL?
    /// Changes with every file opened, so page views and their pictures start afresh.
    private(set) var documentID = UUID()
    /// Each page's upright size in points, read once when the file is opened.
    private(set) var pageSizes: [CGSize] = []
    private(set) var regions: [Region] = []
    private(set) var isFinding = false
    private(set) var isExporting = false
    /// Pages written so far while exporting.
    private(set) var exportedPages = 0
    private(set) var saved: Saved?
    private(set) var notice: String?
    /// What the last Redact All did.
    private(set) var findMessage: String?
    private(set) var zoomIndex = RedactPDFModel.fitZoom
    var selectedRegionID: UUID?
    /// The page at the top of the view, which the scroll view keeps up to date and the list can change.
    var currentPage: Int?
    var query = ""
    var keepSearchable = true {
        didSet { if keepSearchable != oldValue { saved = nil } }
    }

    private var renderer: PDFPageRenderer?
    private var task: Task<Void, Never>?
    private let pictures = NSCache<NSString, PictureBox>()

    private final class PictureBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    init() { pictures.totalCostLimit = 256 * 1024 * 1024 }

    var hasDocument: Bool { url != nil }
    var pageCount: Int { pageSizes.count }
    var fileName: String { url?.lastPathComponent ?? "" }
    var isBusy: Bool { isFinding || isExporting }
    var zoom: CGFloat { Self.zoomLevels[zoomIndex] }
    var canZoomIn: Bool { zoomIndex < Self.zoomLevels.count - 1 }
    var canZoomOut: Bool { zoomIndex > 0 }
    var redactedPageCount: Int { Set(regions.map(\.page)).count }
    var selectedRegion: Region? { regions.first { $0.id == selectedRegionID } }

    /// The boxes in reading order, for the list.
    var sortedRegions: [Region] {
        regions.sorted { ($0.page, $0.rect.minY, $0.rect.minX) < ($1.page, $1.rect.minY, $1.rect.minX) }
    }

    func regions(onPage page: Int) -> [Region] { regions.filter { $0.page == page } }

    // MARK: Opening

    /// Opens a PDF, replacing the one that is open. The original file is only ever read.
    func open(_ url: URL) {
        guard !isBusy else { return }
        let document: PDFDocument
        do { document = try RedactPDF.open(url) } catch {
            notice = error.localizedDescription
            return
        }
        guard let renderer = PDFPageRenderer(url: url) else { notice = RedactPDFError.unreadable.localizedDescription; return }
        reset()
        self.url = url
        self.renderer = renderer
        pageSizes = (0..<document.pageCount).map { document.page(at: $0).map(RedactPDF.uprightSize) ?? CGSize(width: 612, height: 792) }
        currentPage = 0
        Log.info("PDF opened", category: "redact-pdf", ["pages": "\(document.pageCount)"])
    }

    func close() {
        guard !isBusy else { return }
        reset()
        notice = nil
    }

    private func reset() {
        task?.cancel()
        url = nil
        renderer = nil
        documentID = UUID()
        pageSizes = []
        regions = []
        selectedRegionID = nil
        currentPage = nil
        saved = nil
        notice = nil
        findMessage = nil
        query = ""
        zoomIndex = Self.fitZoom
        pictures.removeAllObjects()
    }

    // MARK: Pictures

    /// Page `index` as a picture `pixelWidth` wide. Pictures already drawn are kept for a while, so scrolling back is instant.
    func image(forPage index: Int, pixelWidth: Int) async -> CGImage? {
        let key = "\(documentID.uuidString)-\(index)-\(pixelWidth)" as NSString
        if let hit = pictures.object(forKey: key) { return hit.image }
        guard let renderer else { return nil }
        let id = documentID
        guard let image = await renderer.image(page: index, pixelWidth: pixelWidth), id == documentID else { return nil }
        pictures.setObject(PictureBox(image), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    // MARK: Zoom

    func zoomIn() { if canZoomIn { zoomIndex += 1 } }
    func zoomOut() { if canZoomOut { zoomIndex -= 1 } }

    // MARK: Boxes

    /// Covers a new area of `page` and selects it.
    @discardableResult
    func addRegion(_ rect: CGRect, onPage page: Int) -> UUID? {
        guard !isBusy, page >= 0, page < pageCount else { return nil }
        let region = Region(page: page, rect: RedactImage.fitted(rect), label: nil)
        regions.append(region)
        selectedRegionID = region.id
        changed()
        return region.id
    }

    func setRect(_ rect: CGRect, of id: UUID) {
        guard !isBusy, let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].rect = RedactImage.fitted(rect)
        changed()
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        regions.removeAll { $0.id == id }
        if selectedRegionID == id { selectedRegionID = nil }
        changed()
    }

    func removeSelected() { if let id = selectedRegionID { remove(id) } }

    func clearRegions() {
        guard !isBusy, !regions.isEmpty else { return }
        regions = []
        selectedRegionID = nil
        changed()
    }

    /// Selects a box from the list and brings its page into view.
    func reveal(_ id: UUID) {
        guard let region = regions.first(where: { $0.id == id }) else { return }
        selectedRegionID = id
        currentPage = region.page
    }

    private func changed() { saved = nil }

    // MARK: Find & Redact

    /// Covers every place the text in `query` is printed, on every page. Boxes that are already there stay.
    func redactAll() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url, !text.isEmpty, !isBusy else { return }
        isFinding = true
        findMessage = nil
        let id = documentID
        task = Task { [weak self] in
            // Searching reads the whole file, and a scanned page has to be read by Vision first: not on the main thread.
            let found = await Task.detached(priority: .userInitiated) { () -> RedactPDFFind? in
                guard let document = try? RedactPDF.open(url) else { return nil }
                return RedactPDF.find(text, in: document)
            }.value
            guard let self, !Task.isCancelled, id == documentID else { return }
            finish(find: found, for: text)
        }
    }

    private func finish(find: RedactPDFFind?, for text: String) {
        isFinding = false
        guard let find else {
            findMessage = "The PDF could not be searched."
            Log.error("Find failed", category: "redact-pdf", ["pages": "\(pageSizes.count)", "search_length": "\(text.count)"])
            return
        }
        var added = 0
        var pages = Set<Int>()
        for match in find.matches where !regions.contains(where: { $0.page == match.page && RedactImage.overlaps($0.rect, match.rect) }) {
            regions.append(Region(page: match.page, rect: match.rect, label: match.text))
            pages.insert(match.page)
            added += 1
        }
        if added > 0 { changed() }
        findMessage = Self.summary(matches: find.matches.count, added: added, pages: pages.count, scanned: find.scannedPages, text: text)
        Log.info("Matches covered", category: "redact-pdf", ["found": "\(find.matches.count)", "added": "\(added)", "scanned": "\(find.scannedPages)"])
    }

    nonisolated static func summary(matches: Int, added: Int, pages: Int, scanned: Int, text: String) -> String {
        var message: String
        if matches == 0 {
            message = "No matches for “\(text)”."
        } else if added == 0 {
            message = "Every match is already covered."
        } else {
            message = "Covered \(added) match\(added == 1 ? "" : "es") on \(pages) page\(pages == 1 ? "" : "s")."
        }
        if scanned > 0 {
            message += " \(scanned) scanned page\(scanned == 1 ? " was" : "s were") read, which can miss words, so check \(scanned == 1 ? "it" : "them")."
        }
        return message
    }

    // MARK: Exporting

    /// Asks where to save, then writes the redacted copy there.
    func export() {
        guard let url, !regions.isEmpty, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " (redacted).pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        exportedPages = 0
        saved = nil
        notice = nil
        var boxes: [Int: [CGRect]] = [:]
        for region in regions { boxes[region.page, default: []].append(region.rect) }
        let searchable = keepSearchable
        let count = regions.count
        task = Task { [weak self] in
            // Drawing, reading and encoding every page is heavy; keep it off the main thread.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RedactPDFResult, Error> in
                Result {
                    try RedactPDF.export(source: url, regions: boxes, keepSearchable: searchable, to: destination) { done in
                        Task { @MainActor in self?.exportedPages = done }
                    }
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let result):
                saved = Saved(url: result.url, bytes: result.bytes)
                Log.info("PDF redacted", category: "redact-pdf", ["pages": "\(result.pages)", "redactedPages": "\(result.redactedPages)",
                                                                  "regions": "\(count)", "searchable": "\(searchable)"])
            case .failure(let error):
                notice = error.localizedDescription
                Log.error("Redaction failed", category: "redact-pdf", Log.details(error, file: url))
            }
            isExporting = false
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}
