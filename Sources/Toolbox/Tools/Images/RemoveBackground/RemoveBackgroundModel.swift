import AppKit
import Observation

@MainActor @Observable
final class RemoveBackgroundModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RemoveBackgroundModel()

    enum Status: Equatable {
        case waiting
        case cutting
        case done(RemoveBackgroundResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.waiting
        var thumbnail: CGImage?

        var name: String { url.lastPathComponent }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?
    var selectedID: UUID?

    var settings = RemoveBackgroundSettings()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Queue

    /// Adds photos; folders are searched for images inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        let fresh = found.filter { known.insert(BatchFiles.identity($0)).inserted }
        items += fresh.map {
            Item(url: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        if selectedID == nil { selectedID = items.first?.id }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no images and were skipped."
        for item in items.suffix(fresh.count) { loadThumbnail(item.id, from: item.url) }
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

    private func loadThumbnail(_ id: UUID, from url: URL) {
        Task {
            let thumbnail = await Task.detached(priority: .utility) { ImageConverter.thumbnail(of: url, maxSize: 120) }.value
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].thumbnail = thumbnail
        }
    }

    // MARK: Removing backgrounds

    /// Saves every waiting photo with its background replaced, into one new dated folder in Downloads.
    func removeBackgrounds() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Cutouts")
        self.folder = folder
        let settings = self.settings
        let work = items.filter { $0.status == .waiting }.map { (id: $0.id, url: $0.url) }
        task = Task {
            for job in work {
                if Task.isCancelled { break }
                update(job.id, .cutting)
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RemoveBackgroundResult, Error> in
                    Result { try RemoveBackground.save(source: job.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(job.id, .done(result))
                    Log.info("Background removed", category: "remove-background", ["background": settings.background.rawValue])
                case .failure(let error):
                    update(job.id, .failed(error.localizedDescription))
                    Log.error("Background removal failed", category: "remove-background", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            for i in items.indices where items[i].status == .cutting { items[i].status = .waiting }
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
