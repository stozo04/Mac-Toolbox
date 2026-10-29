import AppKit
import PDFKit
import Observation

/// Something to turn into pages.
enum ScanInput {
    case file(URL)
    /// A photo that is already in memory, such as one taken by an iPhone.
    case photo(CGImage)
    /// A PDF that is already in memory, such as a scan from an iPhone.
    case pdf(Data)
}

struct ScanSettings: Equatable {
    var look = ScanLook.color
    var pageSize = ScanPageSize.matchScan
    var makeSearchable = true
}

@MainActor @Observable
final class ScanDocumentModel {
    /// Shared so the pages survive switching to another tool and back.
    static let shared = ScanDocumentModel()

    struct Page: Identifiable {
        let id = UUID()
        /// The page, cut out and straightened. Rotation and the look are applied when it is shown or saved.
        let image: CGImage
        /// False when no page edges were found and the whole picture is used.
        let foundEdges: Bool
        /// Clockwise quarter turns.
        var turns = 0
    }

    struct SavedPDF: Equatable {
        let url: URL
        let bytes: Int64
        let pages: Int
    }

    private(set) var pages: [Page] = []
    private(set) var thumbnails: [UUID: CGImage] = [:]
    private(set) var isAdding = false
    private(set) var isSaving = false
    /// Pages written so far while saving.
    private(set) var savedPages = 0
    private(set) var saved: SavedPDF?
    private(set) var notice: String?

    var settings = ScanSettings() {
        didSet {
            if settings.look != oldValue.look { refreshAllThumbnails() }
            if settings != oldValue { saved = nil }
        }
    }

    private var inbox: [ScanInput] = []
    private var skipped = 0
    private var worker: Task<Void, Never>?

    var hasPages: Bool { !pages.isEmpty }
    /// Pages whose edges could not be found, so the whole photo was used.
    var uncroppedCount: Int { pages.filter { !$0.foundEdges }.count }

    // MARK: Adding

    /// Photos, PDFs and folders of them. They are processed one at a time, in order.
    func add(_ urls: [URL]) { enqueue(urls.map { .file($0) }) }

    func enqueue(_ inputs: [ScanInput]) {
        guard !inputs.isEmpty else { return }
        inbox += inputs
        isAdding = true
        notice = nil
        if worker == nil { worker = Task { [weak self] in await self?.drain() } }
    }

    private func drain() async {
        skipped = 0
        while !inbox.isEmpty {
            let input = inbox.removeFirst()
            // Finding the edges and straightening a photo takes a moment; keep it off the main thread.
            let scanned = await Task.detached(priority: .userInitiated) { Self.scan(input) }.value
            // Clear was pressed while this one was being read: its pages are not wanted any more.
            if Task.isCancelled { return }
            if scanned.isEmpty { skipped += 1 }
            for page in scanned { append(page) }
        }
        if skipped > 0 { notice = "\(skipped) item\(skipped == 1 ? "" : "s") had no pages and \(skipped == 1 ? "was" : "were") skipped." }
        isAdding = false
        worker = nil
    }

    private nonisolated static func scan(_ input: ScanInput) -> [ScannedPage] {
        switch input {
        case .file(let url): DocumentScanner.scan(file: url)
        case .photo(let image): [DocumentScanner.scan(photo: image)]
        case .pdf(let data): PDFDocument(data: data).map { DocumentScanner.scan(pdf: $0) } ?? []
        }
    }

    private func append(_ scanned: ScannedPage) {
        let page = Page(image: scanned.image, foundEdges: scanned.foundEdges)
        pages.append(page)
        saved = nil
        refreshThumbnail(of: page.id)
        Log.info("Page scanned", category: "scan-document", ["edges": "\(scanned.foundEdges)"])
    }

    // MARK: Editing

    func rotate(_ id: UUID, by turns: Int) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[i].turns = ((pages[i].turns + turns) % 4 + 4) % 4
        saved = nil
        refreshThumbnail(of: id)
    }

    func remove(_ id: UUID) {
        pages.removeAll { $0.id == id }
        thumbnails[id] = nil
        saved = nil
    }

    /// Gives page `id` the place of page `target`; the pages between shift over.
    func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = pages.firstIndex(where: { $0.id == id }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saved = nil
    }

    func clear() {
        inbox = []
        worker?.cancel()
        worker = nil
        pages = []
        thumbnails = [:]
        saved = nil
        notice = nil
        isAdding = false
    }

    // MARK: Pictures

    /// 1-based position of a page, for the number under its picture.
    func number(of id: UUID) -> Int { (pages.firstIndex { $0.id == id } ?? 0) + 1 }

    private func refreshAllThumbnails() { for page in pages { refreshThumbnail(of: page.id) } }

    private func refreshThumbnail(of id: UUID) {
        guard let page = pages.first(where: { $0.id == id }) else { return }
        let look = settings.look
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                DocumentScanner.bitmap(page.image, turns: page.turns, look: look, maxPixel: 420)
            }.value
            guard let self, let image,
                  let current = pages.first(where: { $0.id == id }), current.turns == page.turns, settings.look == look else { return }
            thumbnails[id] = image
        }
    }

    /// The page as it will be saved, but small enough to look at.
    func preview(of id: UUID) async -> CGImage? {
        guard let page = pages.first(where: { $0.id == id }) else { return nil }
        let look = settings.look
        return await Task.detached(priority: .userInitiated) {
            DocumentScanner.bitmap(page.image, turns: page.turns, look: look, maxPixel: 1800)
        }.value
    }

    // MARK: Saving

    func save() {
        guard hasPages, !isSaving else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = "Scan \(Self.stamp()).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isSaving = true
        savedPages = 0
        saved = nil
        notice = nil
        let export = pages.map { ScanExportPage(image: $0.image, turns: $0.turns) }
        let settings = self.settings
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                Result {
                    let data = try DocumentScanner.makePDF(pages: export, look: settings.look, pageSize: settings.pageSize,
                                                           searchable: settings.makeSearchable) { done in
                        Task { @MainActor in self?.savedPages = done }
                    }
                    try data.write(to: url, options: .atomic)
                    return data.count
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let bytes):
                saved = SavedPDF(url: url, bytes: Int64(bytes), pages: export.count)
                Log.info("PDF saved", category: "scan-document",
                         ["pages": "\(export.count)", "look": settings.look.rawValue, "pageSize": settings.pageSize.rawValue,
                          "searchable": "\(settings.makeSearchable)"])
            case .failure(let error):
                notice = "The PDF could not be saved."
                Log.error("PDF save failed", category: "scan-document", Log.details(error, file: url))
            }
            isSaving = false
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
