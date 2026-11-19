import AppKit
import Observation

struct DownloadItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case downloading(fraction: Double?, speed: Double?, eta: Int?)
        case done(URL)
        case inVault(URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    var title: String?
    var quality: FormatChoice?
    var state: State = .queued
    var vaultProblem: String?
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
        case unlocking
        case addingToVault(done: Int, total: Int)
        case makingSearchable(done: Int, total: Int)
        case sending
        case locking
        case sent(DriveSender.Result, vault: VaultSendReport?)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .unlocking, .addingToVault, .makingSearchable, .sending, .locking: true
            case .idle, .sent, .failed: false
            }
        }
    }

    static let touchIDCancelled = "Touch ID was cancelled. Nothing was sent."
    static let onlyInVault = "These videos are in the Vault. Tick Add to Vault to send them."
    static let vaultStillOpen = "The Vault didn't lock. Open the Vault page and lock it."
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
    var finishedFiles: [URL] { items.compactMap { if case .done(let file) = $0.state { file } else { nil } } }
    var vaultFiles: [URL] { items.compactMap { if case .inVault(let file) = $0.state { file } else { nil } } }
    var canSend: Bool { !(finishedFiles.isEmpty && vaultFiles.isEmpty) && !isRunning && !sendState.isBusy }

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

    private typealias Download = (id: UUID, file: URL)

    /// Copies every finished download to the Google Drive folder. With Add to Vault on, Touch ID opens the vault, each video
    /// is moved in and made searchable, the vault copies are sent, and the vault is locked again. Without Touch ID the videos
    /// are sent from Downloads and stay out of the vault.
    func sendToGoogle(vault: DownloadVault?) {
        guard canSend else { return }
        let downloads = items.compactMap { item -> Download? in
            if case .done(let file) = item.state { (item.id, file) } else { nil }
        }
        let hasVideos = downloads.contains { VaultItem.kind(of: $0.file) != nil } || !vaultFiles.isEmpty
        guard addToVault, hasVideos, let vault else {
            sendState = .sending
            Task { await sendFromDownloads(downloads, report: nil) }
            return
        }
        sendState = .unlocking
        Task { await sendThroughVault(vault, downloads) }
    }

    private func sendFromDownloads(_ downloads: [Download], report: VaultSendReport?) async {
        guard !downloads.isEmpty else {
            var sentences = [report?.notAddedBecause.map { "These videos are in the Vault and weren't sent. \($0)" } ?? Self.onlyInVault]
            if report?.stillOpen == true { sentences.insert(Self.vaultStillOpen, at: 0) }
            sendState = .failed(sentences.joined(separator: " "))
            return
        }
        finishSend(await copyToDrive(downloads.map(\.file), fromVault: false), report: report)
    }

    private func sendThroughVault(_ vault: DownloadVault, _ downloads: [Download]) async {
        switch await vault.openWithTouchID() {
        case .cancelled:
            sendState = .failed(Self.touchIDCancelled)
        case .unavailable(let reason, let stillOpen):
            sendState = .sending
            await sendFromDownloads(downloads, report: VaultSendReport(notAddedBecause: reason, stillOpen: stillOpen))
        case .opened:
            let videos = downloads.filter { VaultItem.kind(of: $0.file) != nil }
            let others = downloads.filter { VaultItem.kind(of: $0.file) == nil }
            var (report, keptOut) = await moveIn(videos, to: vault)
            let inVault = vault.acceptsFiles ? vaultFiles : []
            if !vault.acceptsFiles { report.lockedBeforeSending = vaultFiles.count }
            let files = others.map(\.file) + keptOut + inVault
            let sent = files.isEmpty ? .success(DriveSender.Result()) : await copyToDrive(files, fromVault: !inVault.isEmpty)
            sendState = .locking
            report.stillOpen = !(await vault.lockAndConfirm())
            finishSend(sent, report: report)
        }
    }

    /// Videos the vault refuses for a reason of their own stay unsent; ones kept out because it closed go from Downloads.
    private func moveIn(_ videos: [Download], to vault: DownloadVault) async -> (VaultSendReport, keptOut: [URL]) {
        var report = VaultSendReport()
        var keptOut: [URL] = []
        var moved: [URL] = []
        for (done, video) in videos.enumerated() {
            guard vault.acceptsFiles else {
                keptOut.append(video.file)
                continue
            }
            sendState = .addingToVault(done: done, total: videos.count)
            do {
                let inVault = try await vault.moveIn(video.file)
                update(video.id) { $0.state = .inVault(inVault); $0.vaultProblem = nil }
                moved.append(inVault)
            } catch VaultMoveError.vaultNotOpen, VaultMoveError.busy {
                keptOut.append(video.file)
            } catch VaultMoveError.originalKept(let reason, let copy) {
                update(video.id) { $0.state = .inVault(copy); $0.vaultProblem = "The copy in Downloads couldn't be deleted, so Clear leaves it there: \(reason)" }
                moved.append(copy)
                VaultLog.failure("Download in the vault but its original stayed", VaultMoveError.originalKept(reason, copy: copy), file: video.file)
            } catch {
                report.failed += 1
                update(video.id) { $0.vaultProblem = error.localizedDescription }
                if VaultNotices.isUnexpected(error) { VaultLog.failure("Download could not go into the vault", error, file: video.file) }
            }
        }
        report.moved = moved.count
        for (done, file) in moved.enumerated() {
            guard vault.acceptsFiles else { break }
            sendState = .makingSearchable(done: done, total: moved.count)
            if await !vault.makeSearchable(file) { report.notSearchable += 1 }
        }
        return (report, keptOut)
    }

    private func copyToDrive(_ files: [URL], fromVault: Bool) async -> Result<DriveSender.Result, Error> {
        sendState = .sending
        let sendToDrive = sendToDrive
        let result = await Task.detached { Result { try sendToDrive(files) } }.value
        if case .failure(let error) = result {
            let nsError = error as NSError
            // Vault file names must not leave the Mac, and a copy error carries the path it failed on.
            let details = fromVault ? ["error_domain": nsError.domain, "error_code": String(nsError.code)] : Log.details(error)
            Log.warning("Send to Google Drive failed", category: "download",
                        details.merging(["files": String(files.count), "from_vault": String(fromVault)]) { $1 })
        }
        return result
    }

    private func finishSend(_ sent: Result<DriveSender.Result, Error>, report: VaultSendReport?) {
        switch sent {
        case .success(let result):
            sendState = .sent(result, vault: report)
            Log.info("Sent to Google Drive", category: "download",
                     ["copied": String(result.copied), "skipped": String(result.skipped), "missing": String(result.missing),
                      "vault_moved": String(report?.moved ?? 0), "vault_failed": String(report?.failed ?? 0),
                      "not_searchable": String(report?.notSearchable ?? 0), "vault_used": String(report?.notAddedBecause == nil),
                      "vault_still_open": String(report?.stillOpen ?? false)])
        case .failure(let error):
            var sentences = [error.localizedDescription]
            if report?.stillOpen == true { sentences.insert(Self.vaultStillOpen, at: 0) }
            if let reason = report?.notAddedBecause { sentences.append("Not added to the Vault: \(reason)") }
            sendState = .failed(sentences.joined(separator: " "))
        }
    }

    var sendSummary: String? {
        switch sendState {
        case .idle: return nil
        case .unlocking: return "Waiting for Touch ID…"
        case .addingToVault(let done, let total): return "Adding to the Vault, \(done + 1) of \(total)…"
        case .makingSearchable(let done, let total): return "Making searchable, \(done + 1) of \(total)…"
        case .sending: return "Sending to Google Drive…"
        case .locking: return "Locking the Vault…"
        case .failed(let message): return message
        case .sent(let result, let vault): return Self.summary(of: result, vault: vault)
        }
    }

    private static func summary(of result: DriveSender.Result, vault: VaultSendReport?) -> String {
        var sentences: [String] = []
        if vault?.stillOpen == true { sentences.append(vaultStillOpen) }
        let added = vault.map { $0.notAddedBecause == nil ? $0.moved : 0 } ?? 0
        var parts = [added > 0 ? "Added \(added) to the Vault and sent \(result.copied) to Google Drive"
                               : "Sent \(result.copied) to Google Drive"]
        if result.skipped > 0 { parts.append("\(result.skipped) already there") }
        if result.missing > 0 { parts.append("\(result.missing) no longer on disk") }
        if let vault {
            if vault.failed > 0 { parts.append("\(vault.failed) couldn't go into the Vault and weren't sent") }
            if vault.notSearchable > 0 { parts.append("\(vault.notSearchable) not searchable yet") }
            if vault.lockedBeforeSending > 0 {
                parts.append("\(vault.lockedBeforeSending) in the Vault weren't sent because it locked; send again")
            }
        }
        sentences.append(parts.joined(separator: ", ") + ".")
        if let reason = vault?.notAddedBecause { sentences.append("Not added to the Vault: \(reason)") }
        if added > 0, vault?.stillOpen == false { sentences.append("The Vault is locked again.") }
        return sentences.joined(separator: " ")
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
