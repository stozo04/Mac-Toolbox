import AppKit
import Observation

@MainActor @Observable
final class CompressVideoModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = CompressVideoModel()

    enum Status: Equatable {
        case waiting
        case compressing(Double)
        case done(VideoCompressResult)
        case notSmaller(originalBytes: Int64)
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

    var settings = VideoCompressSettings()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var results: [VideoCompressResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }
    var savedBytes: Int64 { results.reduce(0) { $0 + $1.savedBytes } }
    var originalBytes: Int64 { results.reduce(0) { $0 + $1.originalBytes } }
    /// Files that could not be made smaller; nothing was written for them.
    var keptCount: Int { items.filter { if case .notSmaller = $0.status { true } else { false } }.count }

    // MARK: Queue

    /// Adds videos; folders are searched for videos inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.videos(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        items += found.filter { known.insert(BatchFiles.identity($0)).inserted }.map { Item(url: $0) }
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

    // MARK: Compressing

    func compress() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Compressed Videos")
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for id in items.filter({ $0.status == .waiting }).map(\.id) {
                if Task.isCancelled { break }
                update(id, .compressing(0))
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                do {
                    let outcome = try await VideoCompressor.compress(source: url, settings: settings, into: folder) { p in
                        Task { @MainActor in self.update(id, .compressing(p), onlyIfCompressing: true) }
                    }
                    switch outcome {
                    case .compressed(let result):
                        update(id, .done(result))
                        Log.info("Video compressed", category: "compress", [
                            "quality": settings.quality.rawValue, "codec": settings.codec.rawValue,
                            "maxSize": settings.maxSize.rawValue, "hardware": String(settings.hardwareEncoder),
                            "savedPercent": String(Int((result.savedFraction * 100).rounded())),
                        ])
                    case .notSmaller(let original, _):
                        update(id, .notSmaller(originalBytes: original))
                    }
                } catch is CancellationError {
                    update(id, .waiting)
                } catch {
                    update(id, .failed(error.localizedDescription))
                    Log.error("Compress failed", category: "compress", Log.details(error, file: url, [
                        "quality": settings.quality.rawValue, "codec": settings.codec.rawValue,
                        "maxSize": settings.maxSize.rawValue, "hardware": String(settings.hardwareEncoder),
                        "removeAudio": String(settings.removeAudio),
                    ]))
                }
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status, onlyIfCompressing: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if onlyIfCompressing, case .compressing = items[i].status {} else if onlyIfCompressing { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
