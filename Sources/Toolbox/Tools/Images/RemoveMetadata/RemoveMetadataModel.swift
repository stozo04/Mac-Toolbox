import AppKit
import ImageIO
import Observation

@MainActor @Observable
final class RemoveMetadataModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RemoveMetadataModel()

    enum Status: Equatable {
        case waiting
        case working
        case done(StripResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// What the photo carries now, read when it was added.
        let found: Set<MetadataKind>
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    var settings = StripSettings()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }

    private var results: [StripResult] {
        items.compactMap { if case .done(let r) = $0.status { r } else { nil } }
    }
    var doneCount: Int { results.count }
    /// How many finished photos actually had something taken out.
    var cleanedCount: Int { results.filter { !$0.removed.isEmpty }.count }
    /// The kinds of details found in the photos waiting to be cleaned.
    var pendingKinds: Set<MetadataKind> {
        items.filter { $0.status == .waiting }.reduce(into: []) { $0.formUnion($1.found) }
    }

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
        for url in found where known.insert(BatchFiles.identity(url)).inserted {
            let reader = CGImageSourceCreateWithURL(url as CFURL, nil)
            items.append(Item(url: url, bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0),
                              found: reader.map { MetadataStripper.scan($0) } ?? []))
        }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no photos and were skipped."
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clear() {
        task?.cancel()
        items = []
        folder = nil
        notice = nil
        isRunning = false
    }

    // MARK: Cleaning

    func removeMetadata() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Clean Photos")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for item in items where item.status == .waiting {
                if Task.isCancelled { break }
                update(item.id, .working)
                // Decoding and encoding can be heavy; keep them off the main thread.
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<StripResult, Error> in
                    Result { try MetadataStripper.strip(source: item.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(item.id, .done(result))
                    Log.info("Metadata removed", category: "remove-metadata", ["kind": item.kind, "keepOrientation": "\(settings.keepOrientation)"])
                case .failure(let error):
                    update(item.id, .failed(error.localizedDescription))
                    Log.error("Metadata removal failed", category: "remove-metadata", Log.details(error, file: item.url))
                }
            }
            for i in items.indices where items[i].status == .working { items[i].status = .waiting }
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
