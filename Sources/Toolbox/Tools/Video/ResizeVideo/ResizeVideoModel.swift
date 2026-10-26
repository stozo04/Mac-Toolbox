import AppKit
import Observation

@MainActor @Observable
final class ResizeVideoModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = ResizeVideoModel()

    enum Status: Equatable {
        case waiting
        case converting(Double)
        case done(URL, bytes: Int64)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status = Status.waiting
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    var preset = SizePreset.all[2] {
        didSet {
            guard let size = preset.size else { return }
            editingBoth = true
            width = Int(size.width)
            height = Int(size.height)
            editingBoth = false
        }
    }
    var width = 1920 { didSet { if width != oldValue && !editingBoth { syncPreset() } } }
    var height = 1080 { didSet { if height != oldValue && !editingBoth { syncPreset() } } }
    var keepAspect = true
    var fit = ResizeFit.blackBars
    var codec = ResizeCodec.h264

    private var task: Task<Void, Never>?
    /// Set while width and height change together, so a half-finished change can't match a preset.
    private var editingBoth = false

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    var settings: ResizeSettings { ResizeSettings(width: width, height: height, keepAspect: keepAspect, fit: fit, codec: codec) }
    var isValidSize: Bool { (2...16384).contains(width) && (2...16384).contains(height) }
    var evenNote: Bool { width % 2 != 0 || height % 2 != 0 }

    func swapSize() {
        editingBoth = true
        (width, height) = (height, width)
        editingBoth = false
        syncPreset()
    }

    /// Typing a size that matches a preset selects it; anything else is Custom.
    private func syncPreset() {
        let match = SizePreset.all.first { $0.size == CGSize(width: width, height: height) } ?? .custom
        if match != preset { preset = match }
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.videos(in: url)
            if found.count == before { skipped += 1 }
        }
        let known = Set(items.map(\.url))
        items += found.filter { !known.contains($0) }.map { Item(url: $0) }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no videos and were skipped."
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

    // MARK: Resizing

    func resize() {
        guard !isRunning, hasPending, isValidSize else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Videos")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for id in items.filter({ $0.status == .waiting }).map(\.id) {
                if Task.isCancelled { break }
                update(id, .converting(0))
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                do {
                    let out = try await VideoResizer.resize(source: url, settings: settings, into: folder) { p in
                        Task { @MainActor in self.update(id, .converting(p), onlyIfConverting: true) }
                    }
                    let bytes = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                    update(id, .done(out, bytes: bytes))
                    Log.info("Resize finished", category: "resize", ["codec": settings.codec.rawValue, "fit": settings.keepAspect ? settings.fit.rawValue : "stretch"])
                } catch is CancellationError {
                    update(id, .waiting)
                } catch {
                    update(id, .failed(error.localizedDescription))
                    Log.error("Resize failed", category: "resize", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status, onlyIfConverting: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if onlyIfConverting, case .converting = items[i].status {} else if onlyIfConverting { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
