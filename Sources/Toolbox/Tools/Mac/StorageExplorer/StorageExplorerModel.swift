import AppKit
import Observation

@MainActor @Observable
final class StorageExplorerModel {
    static let shared = StorageExplorerModel()

    enum Tab { case explore, hogs }

    enum Measure: Equatable {
        case measuring
        case done(HogResult)
    }

    var tab = Tab.hogs
    private(set) var hogs: [SpaceHog]
    private(set) var measures: [String: Measure] = [:]
    private(set) var disk: StorageScanner.DiskUsage?
    private(set) var detail: SpaceHog?
    var selection: Set<URL> = []
    private(set) var lastOutcome: StorageCleaner.Outcome?

    private var measureTask: Task<Void, Never>?
    private let trash: (URL) throws -> Void
    private let delete: (URL) throws -> Void

    init(hogs: [SpaceHog] = SpaceHog.all(),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         delete: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        self.hogs = hogs
        self.trash = trash
        self.delete = delete
    }

    /// Total of everything listed, shown as "Found".
    var found: Int64 {
        measures.values.reduce(0) { sum, m in if case .done(let r) = m { sum + r.total } else { sum } }
    }

    var isMeasuring: Bool { measures.values.contains(.measuring) }

    func result(_ hog: SpaceHog) -> HogResult? {
        if case .done(let r)? = measures[hog.id] { r } else { nil }
    }

    func measureAll() {
        measureTask?.cancel()
        disk = StorageScanner.diskUsage()
        for hog in hogs { measures[hog.id] = .measuring }
        let hogs = self.hogs
        measureTask = Task {
            await withTaskGroup(of: (String, HogResult).self) { group in
                for hog in hogs { group.addTask { (hog.id, StorageScanner.measure(hog)) } }
                for await (id, result) in group {
                    if Task.isCancelled { break }
                    measures[id] = .done(result)
                }
            }
        }
    }

    func open(_ hog: SpaceHog) {
        detail = hog
        lastOutcome = nil
        selection = []
    }

    func back() { detail = nil; selection = [] }

    func toggle(_ item: HogItem) {
        if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
    }

    func selectAll() {
        guard let detail, let r = result(detail) else { return }
        selection = Set(r.items.map(\.url))
    }

    var selectedBytes: Int64 {
        guard let detail, let r = result(detail) else { return 0 }
        return r.items.filter { selection.contains($0.url) }.reduce(0) { $0 + $1.bytes }
    }

    /// Clears the ticked items (to the Trash, or for good when the hog is the Trash itself) and re-measures.
    func clearSelected() {
        guard let hog = detail, let r = result(hog) else { return }
        let chosen = r.items.filter { selection.contains($0.url) }
        let outcome = StorageCleaner.clear(chosen, from: hog, trash: trash, delete: delete)
        lastOutcome = outcome
        selection = []
        Log.info("Storage cleared", category: "storage", ["hog": hog.id, "items": String(chosen.count), "failed": String(outcome.failures.count)])
        measures[hog.id] = .measuring
        Task {
            measures[hog.id] = .done(await Task.detached { StorageScanner.measure(hog) }.value)
            disk = StorageScanner.diskUsage()
        }
    }

    func confirmAndClear() {
        guard let hog = detail else { return }
        let permanent: Bool
        if case .emptyTrash = hog.clearing { permanent = true } else { permanent = false }
        let alert = NSAlert()
        alert.messageText = permanent ? "Delete \(selection.count) item(s) from the Trash for good?" : "Move \(selection.count) item(s) to the Trash?"
        alert.informativeText = permanent
            ? "\(ByteFormat.string(selectedBytes)) will be deleted permanently. This can't be undone."
            : "\(ByteFormat.string(selectedBytes)) will be moved. You can put things back until you empty the Trash."
        alert.alertStyle = permanent ? .critical : .warning
        alert.addButton(withTitle: permanent ? "Delete Permanently" : "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { clearSelected() }
    }
}

/// The Explore tab: browse folder sizes from the home folder down.
@MainActor @Observable
final class FolderExplorer {
    static let shared = FolderExplorer()

    struct Entry: Identifiable, Equatable {
        let url: URL
        let isFolder: Bool
        var bytes: Int64?
        var id: URL { url }
    }

    private(set) var location: URL
    private(set) var entries: [Entry] = []
    private(set) var unreadable = false
    private let home: URL
    private var task: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.location = home
    }

    var canGoUp: Bool { location.standardizedFileURL.path != home.standardizedFileURL.path }
    var largest: Int64 { entries.compactMap(\.bytes).max() ?? 1 }

    func go(to url: URL) {
        task?.cancel()
        location = url
        let names = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        unreadable = names == nil
        entries = (names ?? []).filter { $0.lastPathComponent != ".DS_Store" }.map {
            Entry(url: $0, isFolder: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false, bytes: nil)
        }
        let urls = entries.map(\.url)
        task = Task {
            await withTaskGroup(of: (URL, Int64).self) { group in
                for u in urls { group.addTask { (u, DirectorySize.bytes(of: u)) } }
                for await (u, size) in group {
                    if Task.isCancelled { return }
                    if let i = entries.firstIndex(where: { $0.url == u }) { entries[i].bytes = size }
                    entries.sort { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
                }
            }
        }
    }

    func goUp() { if canGoUp { go(to: location.deletingLastPathComponent()) } }
}
