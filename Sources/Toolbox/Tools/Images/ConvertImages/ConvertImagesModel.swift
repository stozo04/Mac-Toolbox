import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class ConvertImagesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ConvertImagesModel()

    enum Status: Equatable {
        case waiting
        case converting
        case done(ConvertResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.waiting

        /// "HEIC", "JPEG"... from the file's extension.
        var kind: String { ImageFormat.name(forExtension: url.pathExtension) }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    var settings = ConvertSettings()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

    // MARK: Queue

    /// Adds images; folders are searched for images inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += Self.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        items += found.filter { known.insert(BatchFiles.identity($0)).inserted }.map {
            Item(url: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no images and were skipped."
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

    /// The image at `url`, or every image inside a folder (hidden files skipped).
    static func images(in url: URL) -> [URL] {
        let isImage = { (u: URL) in (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isImage(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.compactMap { $0 as? URL } ?? []).filter(isImage).sorted { $0.path < $1.path }
    }

    // MARK: Converting

    func convert() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Converted Images")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for item in items where item.status == .waiting {
                if Task.isCancelled { break }
                update(item.id, .converting)
                // Decoding and encoding are heavy; keep them off the main thread.
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ConvertResult, Error> in
                    Result { try ImageConverter.convert(source: item.url, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(item.id, .done(result))
                    Log.info("Image converted", category: "convert-images", ["from": item.kind, "to": settings.format.ext])
                case .failure(let error):
                    update(item.id, .failed(error.localizedDescription))
                    Log.error("Image conversion failed", category: "convert-images", ["to": settings.format.ext, "reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            for i in items.indices where items[i].status == .converting { items[i].status = .waiting }
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
