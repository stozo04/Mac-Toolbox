import AppKit
import Observation

struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case downloading(fraction: Double?, speed: Double?, eta: Int?)
        case done(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    var title: String?
    var quality: FormatChoice?
    var state: State = .queued
}

enum DownloadAlert: Identifiable {
    case youTubeFailed

    var id: Self { self }
    var title: String { "YouTube download failed" }
    var message: String {
        "If a YouTube download fails, run brew upgrade yt-dlp. YouTube changes often and old versions break."
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "youtu.be"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

@MainActor @Observable
final class DownloadVideoModel {
    /// Shared so a running download survives switching to another tool and back.
    static let shared = DownloadVideoModel()

    enum ToolStatus: Equatable { case checking, ready, missing, installing, installFailed(String) }
    enum SendState: Equatable { case idle, sending, sent(copied: Int, skipped: Int), failed(String) }

    var linkText = ""
    var options = DownloadOptions()
    private(set) var items: [DownloadItem] = []
    private(set) var toolStatus: ToolStatus = .checking
    private(set) var hasFFmpeg = false
    private(set) var folder: URL?
    private(set) var sendState: SendState = .idle
    /// Set when a YouTube link fails; the view shows it as an alert.
    var alert: DownloadAlert?

    private var downloader: Downloader?
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }
    var pendingLinks: [URL] { Self.links(in: linkText) }
    var canStart: Bool { toolStatus == .ready && !pendingLinks.isEmpty && !isRunning }
    var finishedCount: Int { items.filter { if case .done = $0.state { true } else { false } }.count }
    var finishedFiles: [URL] { items.compactMap { if case .done(let file) = $0.state { file } else { nil } } }
    var canSend: Bool { !finishedFiles.isEmpty && !isRunning && sendState != .sending }

    private let saveFolder: URL
    private let trash: (URL) throws -> Void

    /// `saveFolder` and `trash` are injectable so tests never touch the real Downloads folder.
    init(downloader: Downloader? = nil, saveFolder: URL = DownloadVideoModel.downloadsFolder,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.saveFolder = saveFolder
        self.trash = trash
        if let downloader {
            self.downloader = downloader
            toolStatus = .ready
        } else {
            refreshTool()
        }
    }

    /// Extracts http(s) links from pasted text, one per whitespace-separated token, without repeats.
    nonisolated static func links(in text: String) -> [URL] {
        var seen = Set<URL>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { token in
            guard let url = URL(string: String(token)), ["http", "https"].contains(url.scheme?.lowercased()),
                  url.host?.contains(".") == true, seen.insert(url).inserted else { return nil }
            return url
        }
    }

    func refreshTool() {
        downloader = YtDlpLocator.makeDownloader()
        hasFFmpeg = YtDlpLocator.findFFmpeg() != nil
        toolStatus = downloader == nil ? .missing : .ready
    }

    func installTool() {
        toolStatus = .installing
        Task {
            do {
                try await YtDlpLocator.install()
                refreshTool()
                Log.info("yt-dlp installed", category: "download")
            } catch {
                toolStatus = .installFailed(error.localizedDescription)
                Log.warning("yt-dlp install failed", category: "download", Log.details(error))
            }
        }
    }

    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        linkText = linkText.isEmpty ? text : linkText + "\n" + text
    }

    func start() {
        guard canStart, let downloader else { return }
        let urls = pendingLinks
        linkText = ""
        sendState = .idle
        let destination = saveFolder
        folder = destination
        let ids = urls.map { url -> UUID in
            let item = DownloadItem(url: url)
            items.append(item)
            return item.id
        }
        let options = options
        runTask = Task { [weak self] in
            for id in ids {
                guard let self else { return }
                await self.run(id: id, downloader: downloader, options: options, folder: destination)
            }
            self?.runTask = nil
        }
    }

    func cancel() { runTask?.cancel() }

    /// Clears the list and moves the files this tool downloaded to the Trash (nothing else in the folder).
    /// A file that can't be trashed, or is already gone, is left alone.
    func clearFinished() {
        guard !isRunning else { return }
        for file in finishedFiles { try? trash(file) }
        items.removeAll()
        folder = nil
        sendState = .idle
    }

    /// Copies every finished download to the Google Drive folder.
    func sendToGoogle() {
        guard canSend else { return }
        let files = finishedFiles
        sendState = .sending
        Task {
            do {
                let result = try await Task.detached { try DriveSender.send(files) }.value
                sendState = .sent(copied: result.copied, skipped: result.skipped)
                Log.info("Sent to Google Drive", category: "download",
                         ["copied": String(result.copied), "skipped": String(result.skipped)])
            } catch {
                sendState = .failed(error.localizedDescription)
                Log.warning("Send to Google Drive failed", category: "download", Log.details(error, ["files": String(files.count)]))
            }
        }
    }

    func reveal(_ item: DownloadItem) {
        if case .done(let file) = item.state { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    func openFolder() {
        if let folder { NSWorkspace.shared.open(folder) }
    }

    private func run(id: UUID, downloader: Downloader, options: DownloadOptions, folder: URL) async {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        if Task.isCancelled { update(id) { $0.state = .cancelled }; return }
        update(id) { $0.state = .downloading(fraction: nil, speed: nil, eta: nil) }
        do {
            let file = try await downloader.download(url: url, options: options, into: folder) { [weak self] event in
                Task { @MainActor in self?.apply(event, to: id) }
            }
            update(id) { $0.state = .done(file) }
            let quality = items.first(where: { $0.id == id })?.quality
            Log.info("Download finished", category: "download",
                     ["host": url.host ?? "unknown", "quality": quality?.summary ?? "unknown"])
        } catch is CancellationError {
            update(id) { $0.state = .cancelled }
        } catch {
            update(id) { $0.state = .failed(error.localizedDescription) }
            // The link goes in without its query string (tokens live there); titles are not logged.
            Log.error("Download failed", category: "download",
                      Log.details(error, ["url": LogText.safeURL(url), "host": url.host ?? "unknown",
                                          "format": options.format.rawValue, "compatible": String(options.mostCompatible)]))
            if DownloadAlert.isYouTube(url) { alert = .youTubeFailed }
        }
    }

    private func apply(_ event: DownloadEvent, to id: UUID) {
        update(id) { item in
            switch event {
            case .title(let t): item.title = t
            case .chosen(let choice): item.quality = choice
            case .progress(let f, let s, let e):
                // A late event must not undo a finished state.
                if case .downloading = item.state { item.state = .downloading(fraction: f, speed: s, eta: e) }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    /// Every batch saves straight into the user's Downloads folder.
    nonisolated static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }
}
