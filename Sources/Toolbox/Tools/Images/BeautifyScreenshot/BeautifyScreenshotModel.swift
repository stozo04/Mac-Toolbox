import AppKit
import Observation

@MainActor @Observable
final class BeautifyScreenshotModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BeautifyScreenshotModel()

    enum Status: Equatable {
        /// Reading the screenshot's size; it can't be previewed yet.
        case loading
        case waiting
        case framing
        case done(BeautifyResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.loading
        var pixelSize = CGSize.zero
        var thumbnail: CGImage?

        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?
    var selectedID: UUID?

    var settings = BeautifySettings()

    private var loader: Task<Void, Never>?
    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var isLoading: Bool { items.contains { $0.status == .loading } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Queue

    /// Adds screenshots; folders are searched for images inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        items += found.filter { known.insert(BatchFiles.identity($0)).inserted }.map {
            Item(url: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        if selectedID == nil { selectedID = items.first?.id }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no images and were skipped."
        readItems()
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        task?.cancel()
        items = []
        selectedID = nil
        folder = nil
        notice = nil
        isRunning = false
    }

    // MARK: Reading

    /// Reads the size and a thumbnail of each new screenshot, in the background.
    private func readItems() {
        guard loader == nil else { return }
        loader = Task {
            while let item = items.first(where: { $0.status == .loading }) {
                let url = item.url
                let info = await Task.detached(priority: .userInitiated) { BeautifyScreenshot.inspect(url) }.value
                guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[i].pixelSize = info.size
                items[i].thumbnail = info.thumbnail
                items[i].status = .waiting
            }
            loader = nil
        }
    }

    // MARK: Framing

    /// Saves every waiting screenshot framed with the current settings, into one new dated folder in Downloads.
    func beautify() {
        guard !isRunning, hasPending, !isLoading else { return }
        isRunning = true
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Beautified Screenshots")
        self.folder = folder
        let settings = self.settings
        let work = items.filter { $0.status == .waiting }.map { (id: $0.id, url: $0.url) }
        task = Task {
            for job in work {
                if Task.isCancelled { break }
                update(job.id, .framing)
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<BeautifyResult, Error> in
                    Result { try BeautifyScreenshot.save(source: job.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(job.id, .done(result))
                    Log.info("Screenshot framed", category: "beautify-screenshot", ["background": settings.background.rawValue, "ratio": settings.ratio.rawValue])
                case .failure(let error):
                    update(job.id, .failed(error.localizedDescription))
                    Log.error("Screenshot framing failed", category: "beautify-screenshot", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            for i in items.indices where items[i].status == .framing { items[i].status = .waiting }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
