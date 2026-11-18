import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class BurnInSubtitlesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BurnInSubtitlesModel()

    enum Source: String, CaseIterable, Identifiable {
        case file = "Subtitle File", transcribe = "Transcribe Automatically"
        var id: String { rawValue }
    }

    enum Status: BatchStatus {
        case waiting
        case transcribing(Double)
        case burning(Double)
        case done(BurnResult)
        case failed(String)

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        /// A subtitle file with the video's name next to it.
        let sidecar: URL?
        var status = Status.waiting
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Subtitled Videos", logCategory: "burn-in", failureLog: "Burn in failed",
                                     skippedBecause: "had no videos", files: BatchFiles.videos), outputParent: outputParent)
    }

    var source = Source.file
    private(set) var chosenFile: URL?
    var alsoSaveSubtitles = false
    var languageID = ""
    var style = CaptionStyle()

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
    var hasPending: Bool { queue.hasWaiting }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }

    // MARK: Queue

    func add(_ urls: [URL]) { queue.add(urls) { Item(url: $0, sidecar: SubtitleFile.sidecar(for: $0)) } }

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
            queue.notice = nil
        } catch {
            queue.notice = error.localizedDescription
        }
    }

    // MARK: Burning

    func burn() {
        guard hasRunnable else { return }
        let (source, style, save) = (self.source, self.style, alsoSaveSubtitles)
        let locale = Locale(identifier: languageID)
        queue.run(where: isReady) { [self] item, folder, step in
            let cues: [SubtitleCue]
            switch source {
            case .file:
                guard let file = subtitleFile(for: item) else { return .waiting }
                cues = try SubtitleFile.load(file)
            case .transcribe:
                let words = try await SpeechTranscriber.transcribe(item.url, locale: locale, progress: step.progress { .transcribing($0) })
                cues = CueBuilder.cues(from: words)
                if save { try Self.writeSRT(cues, for: item.url, into: folder) }
            }
            let result = try await SubtitleBurner.burn(source: item.url, cues: cues, style: style, into: folder,
                                                       progress: step.progress { .burning($0) })
            Log.info("Subtitles burned in", category: "burn-in", ["source": source == .file ? "file" : "speech", "style": style.look == .box ? "box" : "shadow"])
            return .done(result)
        }
    }

    nonisolated static func writeSRT(_ cues: [SubtitleCue], for video: URL, into folder: URL) throws {
        let url = BatchFiles.uniqueURL(in: folder, name: video.deletingPathExtension().lastPathComponent, ext: "srt")
        try SubtitleFile.srt(cues).write(to: url, atomically: true, encoding: .utf8)
    }
}
