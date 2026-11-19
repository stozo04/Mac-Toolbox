import AppKit
import Observation

struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case downloading(fraction: Double?, speed: Double?, eta: Int?)
        case done(URL)
        /// Moved out of Downloads into the vault; the URL is its place inside the vault.
        case inVault(URL)
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
    enum SendState: Equatable {
        case idle
        case addingToVault(done: Int, total: Int)
        case makingSearchable(done: Int, total: Int)
        case sending
        case sent(copied: Int, skipped: Int, vault: VaultSendReport?)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .addingToVault, .makingSearchable, .sending: true
            case .idle, .sent, .failed: false
            }
        }
    }

    static let unlockVaultFirst = "Unlock the Vault first. Nothing was sent."
    static let vaultLockedMidway = "The Vault locked before the videos were sent to Google. Unlock it and send again."
    private static let addToVaultKey = "downloadVideo.addToVault"

    var linkText = ""
    var options = DownloadOptions()
    private(set) var items: [DownloadItem] = []
    private(set) var toolStatus: ToolStatus = .checking
    private(set) var hasFFmpeg = false
    private(set) var folder: URL?
    private(set) var sendState: SendState = .idle
    /// Set when a YouTube link fails; the view shows it as an alert.
    var alert: DownloadAlert?
    var addToVault: Bool {
        didSet { defaults.set(addToVault, forKey: Self.addToVaultKey) }
    }

    private var downloader: Downloader?
    private var runTask: Task<Void, Never>?

    var isRunning: Bool { runTask != nil }
    var pendingLinks: [URL] { Self.links(in: linkText) }
    var canStart: Bool { toolStatus == .ready && !pendingLinks.isEmpty && !isRunning && !sendState.isBusy }
    var finishedCount: Int { finishedFiles.count + vaultFiles.count }
    /// Finished downloads still in the Downloads folder.
    var finishedFiles: [URL] { items.compactMap { if case .done(let file) = $0.state { file } else { nil } } }
    var vaultFiles: [URL] { items.compactMap { if case .inVault(let file) = $0.state { file } else { nil } } }
    var canSend: Bool { !(finishedFiles.isEmpty && vaultFiles.isEmpty) && !isRunning && !sendState.isBusy }
    var canAddToVault: Bool { !vaultFiles.isEmpty || finishedFiles.contains { VaultItem.kind(of: $0) != nil } }

    private let saveFolder: URL
    private let trash: (URL) throws -> Void
    private let sendToDrive: @Sendable ([URL]) throws -> DriveSender.Result
    private let defaults: UserDefaults

    /// `saveFolder`, `trash`, `sendToDrive` and `defaults` are injectable so tests never touch the real Downloads folder,
    /// Google Drive or settings.
    init(downloader: Downloader? = nil, saveFolder: URL = DownloadVideoModel.downloadsFolder,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         sendToDrive: @escaping @Sendable ([URL]) throws -> DriveSender.Result = { try DriveSender.send($0) },
         defaults: UserDefaults = .standard) {
        self.saveFolder = saveFolder
        self.trash = trash
        self.sendToDrive = sendToDrive
        self.defaults = defaults
        addToVault = defaults.bool(forKey: Self.addToVaultKey)
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
        hasFFmpeg = MediaTools.ffmpeg() != nil
        toolStatus = downloader == nil ? .missing : .ready
    }

    func installTool() {
        toolStatus = .installing
        Task {
            do {
                try await YtDlpInstaller().install()
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
    /// A file that can't be trashed, or is already gone, is left alone. Files moved into the vault stay there.
    func clearFinished() {
        guard !isRunning, !sendState.isBusy else { return }
        for file in finishedFiles { try? trash(file) }
        items.removeAll()
        folder = nil
        sendState = .idle
    }

    /// Copies every finished download to the Google Drive folder. With Add to Vault on, each one is first moved into the
    /// vault and made searchable there, and only what reached the vault is sent, from its copy in the vault.
    func sendToGoogle(vault: DownloadVault?) {
        guard canSend else { return }
        let usesVault = addToVault
        if usesVault && vault?.acceptsFiles != true {
            sendState = .failed(Self.unlockVaultFirst)
            return
        }
        sendState = usesVault ? .addingToVault(done: 0, total: finishedFiles.count) : .sending
        Task {
            var report: VaultSendReport?
            if usesVault, let vault { report = await addFinishedDownloads(to: vault) }
            let vaultOpen = vault?.acceptsFiles == true
            if usesVault && !vaultOpen {
                sendState = .failed(Self.vaultLockedMidway)
                Log.warning("Vault locked before sending to Google Drive", category: "download")
                return
            }
            await copyToDrive(usesVault ? vaultFiles : finishedFiles + (vaultOpen ? vaultFiles : []), report: report)
        }
    }

    private func addFinishedDownloads(to vault: DownloadVault) async -> VaultSendReport {
        let downloads = items.compactMap { item -> (id: UUID, file: URL)? in
            if case .done(let file) = item.state { (item.id, file) } else { nil }
        }
        var report = VaultSendReport()
        var moved: [URL] = []
        for (done, download) in downloads.enumerated() {
            guard vault.acceptsFiles else { break }
            sendState = .addingToVault(done: done, total: downloads.count)
            do {
                let inVault = try await vault.moveIn(download.file)
                update(download.id) { $0.state = .inVault(inVault) }
                moved.append(inVault)
            } catch {
                report.failed += 1
                if VaultNotices.isUnexpected(error) { VaultLog.failure("Download could not go into the vault", error, file: download.file) }
            }
        }
        report.moved = moved.count
        for (done, file) in moved.enumerated() {
            guard vault.acceptsFiles else { break }
            sendState = .makingSearchable(done: done, total: moved.count)
            if await !vault.makeSearchable(file) { report.notSearchable += 1 }
        }
        return report
    }

    private func copyToDrive(_ files: [URL], report: VaultSendReport?) async {
        guard !files.isEmpty else {
            sendState = .sent(copied: 0, skipped: 0, vault: report)
            return
        }
        sendState = .sending
        let sendToDrive = sendToDrive
        do {
            let result = try await Task.detached { try sendToDrive(files) }.value
            sendState = .sent(copied: result.copied, skipped: result.skipped, vault: report)
            Log.info("Sent to Google Drive", category: "download",
                     ["copied": String(result.copied), "skipped": String(result.skipped),
                      "vault_moved": String(report?.moved ?? 0), "vault_failed": String(report?.failed ?? 0),
                      "not_searchable": String(report?.notSearchable ?? 0)])
        } catch {
            sendState = .failed(error.localizedDescription)
            Log.warning("Send to Google Drive failed", category: "download", Log.details(error, ["files": String(files.count)]))
        }
    }

    var sendSummary: String? {
        switch sendState {
        case .idle: return nil
        case .addingToVault(let done, let total): return "Adding to the Vault, \(done + 1) of \(total)…"
        case .makingSearchable(let done, let total): return "Making searchable, \(done + 1) of \(total)…"
        case .sending: return "Sending to Google Drive…"
        case .failed(let message): return message
        case .sent(let copied, let skipped, let vault):
            if let vault, vault.moved == 0, copied == 0, skipped == 0 { return "Nothing went into the Vault, so nothing was sent" }
            var parts = ["Sent \(copied) to Google Drive"]
            if skipped > 0 { parts.append("\(skipped) already there") }
            if let vault, vault.failed > 0 { parts.append("\(vault.failed) couldn't go into the Vault and weren't sent") }
            if let vault, vault.notSearchable > 0 { parts.append("\(vault.notSearchable) not searchable yet") }
            return parts.joined(separator: ", ")
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
