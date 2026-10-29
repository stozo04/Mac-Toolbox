import AppKit
import Observation

@MainActor @Observable
final class MuteVideoModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = MuteVideoModel()

    enum Status: Equatable {
        case waiting
        case muting(Double)
        case done(MuteResult)
        case silent
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

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var results: [MuteResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }
    var savedBytes: Int64 { results.reduce(0) { $0 + $1.savedBytes } }

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

    // MARK: Muting

    func mute() {
        guard !isRunning, hasPending else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Muted Videos")
        self.folder = folder
        task = Task { [weak self] in
            guard let self else { return }
            for id in items.filter({ $0.status == .waiting }).map(\.id) {
                if Task.isCancelled { break }
                update(id, .muting(0))
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                do {
                    let outcome = try await VideoMuter.mute(source: url, into: folder) { p in
                        Task { @MainActor in self.update(id, .muting(p), onlyIfMuting: true) }
                    }
                    switch outcome {
                    case .muted(let result):
                        update(id, .done(result))
                        Log.info("Video muted", category: "mute", ["reencoded": String(result.reencoded)])
                    case .alreadySilent:
                        update(id, .silent)
                    }
                } catch is CancellationError {
                    update(id, .waiting)
                } catch {
                    update(id, .failed(error.localizedDescription))
                    Log.error("Mute failed", category: "mute", Log.details(error, file: url))
                }
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status, onlyIfMuting: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if onlyIfMuting, case .muting = items[i].status {} else if onlyIfMuting { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
