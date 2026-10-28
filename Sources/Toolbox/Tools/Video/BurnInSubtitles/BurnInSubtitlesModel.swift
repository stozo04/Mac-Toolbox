import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class BurnInSubtitlesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BurnInSubtitlesModel()

    enum Source: String, CaseIterable, Identifiable {
        case file = "Subtitle File", transcribe = "Transcribe Automatically"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case waiting
        case transcribing(Double)
        case burning(Double)
        case done(BurnResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        /// A subtitle file with the video's name next to it.
        let sidecar: URL?
        var status = Status.waiting
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?

    var source = Source.file
    private(set) var chosenFile: URL?
    var alsoSaveSubtitles = false
    var languageID = ""
    var style = CaptionStyle()

    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }

    /// Languages this Mac can transcribe; empty until `loadLanguages()` has run.
    private(set) var locales: [Locale] = []

    /// Looks the languages up the first time automatic transcription is chosen.
    func loadLanguages() {
        guard locales.isEmpty else { return }
        locales = SpeechTranscriber.onDeviceLocales
        if languageID.isEmpty || !locales.contains(where: { $0.identifier == languageID }) {
            languageID = SpeechTranscriber.defaultLocale(in: locales)?.identifier ?? ""
        }
    }

    /// The subtitle file a video would use right now, in file mode.
    func subtitleFile(for item: Item) -> URL? { item.sidecar ?? chosenFile }

    func isReady(_ item: Item) -> Bool { item.status == .waiting && (source == .transcribe || subtitleFile(for: item) != nil) }
    var hasRunnable: Bool { items.contains(where: isReady) }
    var hasPending: Bool { items.contains { $0.status == .waiting } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

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
        items += found.filter { known.insert(BatchFiles.identity($0)).inserted }.map { Item(url: $0, sidecar: SubtitleFile.sidecar(for: $0)) }
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

    // MARK: Subtitle file

    func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SubtitleFile.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSubtitleFile(url)
    }

    func setSubtitleFile(_ url: URL) {
        do {
            _ = try SubtitleFile.load(url)
            chosenFile = url
            notice = nil
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Burning

    func burn() {
        guard !isRunning, hasRunnable else { return }
        isRunning = true
        for i in items.indices { if case .failed = items[i].status { items[i].status = .waiting } }
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Subtitled Videos")
        self.folder = folder
        let (source, style, save) = (self.source, self.style, alsoSaveSubtitles)
        let locale = Locale(identifier: languageID)
        task = Task { [weak self] in
            guard let self else { return }
            for item in items where isReady(item) {
                if Task.isCancelled { break }
                let id = item.id
                do {
                    let cues: [SubtitleCue]
                    switch source {
                    case .file:
                        guard let file = subtitleFile(for: item) else { continue }
                        cues = try SubtitleFile.load(file)
                    case .transcribe:
                        update(id, .transcribing(0))
                        let words = try await SpeechTranscriber.transcribe(item.url, locale: locale) { p in
                            Task { @MainActor in self.update(id, .transcribing(p), only: .transcribing) }
                        }
                        cues = CueBuilder.cues(from: words)
                        if save { try Self.writeSRT(cues, for: item.url, into: folder) }
                    }
                    update(id, .burning(0))
                    let result = try await SubtitleBurner.burn(source: item.url, cues: cues, style: style, into: folder) { p in
                        Task { @MainActor in self.update(id, .burning(p), only: .burning) }
                    }
                    update(id, .done(result))
                    Log.info("Subtitles burned in", category: "burn-in", ["source": source == .file ? "file" : "speech", "style": style.look == .box ? "box" : "shadow"])
                } catch is CancellationError {
                    update(id, .waiting)
                } catch {
                    update(id, .failed(error.localizedDescription))
                    Log.error("Burn in failed", category: "burn-in", ["reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    nonisolated static func writeSRT(_ cues: [SubtitleCue], for video: URL, into folder: URL) throws {
        let url = BatchFiles.uniqueURL(in: folder, name: video.deletingPathExtension().lastPathComponent, ext: "srt")
        try SubtitleFile.srt(cues).write(to: url, atomically: true, encoding: .utf8)
    }

    private enum Phase { case transcribing, burning }

    private func update(_ id: UUID, _ status: Status, only phase: Phase? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch (phase, items[i].status) {
        case (nil, _), (.transcribing, .transcribing), (.burning, .burning): items[i].status = status
        default: break
        }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
