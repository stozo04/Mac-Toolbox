import AppKit
import Observation

@MainActor @Observable
final class ExtractAudioModel {
    static let shared = ExtractAudioModel()
    static let outputFolderName = "Toolbox Extracted Audio"

    enum Status: Equatable {
        case waiting
        case extracting(Double)
        case done(ExtractAudioResult)
        case noSoundtrack
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var status = Status.waiting

        var isFailed: Bool { if case .failed = status { true } else { false } }
    }

    var settings = ExtractAudioSettings()
    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    private var task: Task<Void, Never>?
    private var currentRun: UUID?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .waiting || $0.isFailed } }
    var results: [ExtractAudioResult] { items.compactMap { if case .done(let r) = $0.status { r } else { nil } } }

    // MARK: Queue

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
        currentRun = nil
        items = []
        folder = nil
        notice = nil
        isRunning = false
    }

    // MARK: Extracting

    func extract() {
        guard !isRunning, hasPending else { return }
        let folder: URL
        do { folder = try self.folder ?? BatchFiles.makeOutputFolder(named: Self.outputFolderName) } catch {
            notice = error.localizedDescription
            Log.error("Output folder failed", category: "extractAudio", Log.details(error))
            return
        }
        isRunning = true
        for i in items.indices where items[i].isFailed { items[i].status = .waiting }
        let run = UUID()
        currentRun = run
        self.folder = folder
        let settings = self.settings
        task = Task { [weak self] in
            guard let self else { return }
            for id in items.filter({ $0.status == .waiting }).map(\.id) {
                if Task.isCancelled { break }
                guard currentRun == run else { break }
                update(id, .extracting(0), run: run)
                guard let url = items.first(where: { $0.id == id })?.url else { continue }
                do {
                    let outcome = try await AudioExtractor.extract(source: url, into: folder, settings: settings) { p in
                        Task { @MainActor in self.update(id, .extracting(p), run: run, onlyIfExtracting: true) }
                    }
                    switch outcome {
                    case .extracted(let result):
                        update(id, .done(result), run: run)
                        Log.info("Audio extracted", category: "extractAudio",
                                 ["format": settings.format.rawValue, "bitrate": String(settings.bitrate.rawValue),
                                  "copiedAsIs": String(result.copiedAsIs)])
                    case .noSoundtrack:
                        update(id, .noSoundtrack, run: run)
                    }
                } catch is CancellationError {
                    update(id, .waiting, run: run)
                } catch {
                    update(id, .failed(error.localizedDescription), run: run)
                    Log.error("Extract audio failed", category: "extractAudio",
                              Log.details(error, file: url, ["format": settings.format.rawValue,
                                                             "bitrate": String(settings.bitrate.rawValue)]))
                }
            }
            if currentRun == run {
                currentRun = nil
                isRunning = false
            }
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status, run: UUID, onlyIfExtracting: Bool = false) {
        guard currentRun == run, let i = items.firstIndex(where: { $0.id == id }) else { return }
        if onlyIfExtracting, case .extracting = items[i].status {} else if onlyIfExtracting { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
