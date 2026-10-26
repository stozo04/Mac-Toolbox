import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class VideoToGifModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = VideoToGifModel()

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

    var fps = 15
    var maxWidth: Int? = 480
    var loopForever = true
    var partOnly = false
    var startText = "0:00.00"
    var lengthText = "0:05.00"

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

    /// Nil when the part fields can't be read; the UI shows why.
    var settings: GifSettings? {
        var s = GifSettings(fps: fps, maxWidth: maxWidth, loopForever: loopForever)
        if partOnly {
            guard let start = TrimTime.parse(startText), let length = TrimTime.parse(lengthText), length > 0 else { return nil }
            s.part = (start, length)
        }
        return s
    }

    // MARK: Queue

    /// Adds videos; folders are searched for videos inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += Self.videos(in: url)
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

    /// Drops finished items so a new batch can start.
    func removeFinished() {
        items.removeAll { if case .done = $0.status { true } else { false } }
    }

    private static func videos(in url: URL) -> [URL] {
        let isVideo = { (u: URL) in (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .movie) ?? false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isVideo(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.compactMap { $0 as? URL } ?? []).filter(isVideo).sorted { $0.path < $1.path }
    }

    // MARK: Converting

    func convert() {
        guard !isRunning, hasPending, let settings else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? Self.makeFolder()
        self.folder = folder
        task = Task { [weak self] in
            guard let self else { return }
            for id in items.filter({ $0.status == .waiting }).map(\.id) {
                if Task.isCancelled { break }
                update(id, .converting(0))
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                do {
                    let gif = try await GifConverter.convert(source: url, settings: settings, into: folder) { p in
                        Task { @MainActor in self.update(id, .converting(p), onlyIfConverting: true) }
                    }
                    let bytes = (try? gif.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
                    update(id, .done(gif, bytes: bytes))
                    Log.info("GIF finished", category: "gif", ["fps": String(settings.fps), "part": String(settings.part != nil)])
                } catch is CancellationError {
                    update(id, .waiting)
                } catch {
                    update(id, .failed(error.localizedDescription))
                    Log.error("GIF failed", category: "gif", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
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

    /// A new dated folder in Downloads for each batch, e.g. "Toolbox GIFs 2026-10-26 14.30.05".
    private static func makeFolder() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("Toolbox GIFs \(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
