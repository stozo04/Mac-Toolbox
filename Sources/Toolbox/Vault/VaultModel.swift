import AppKit
import AVFoundation
import VaultSearch
import Observation

@MainActor
@Observable
final class VaultModel {
    enum Phase: Equatable { case setup, locked, opening, open }

    enum Mode: String, CaseIterable, Identifiable {
        case library, duplicates

        var id: Self { self }
        var title: String { self == .library ? "Library" : "Duplicates" }
    }

    enum SearchState: Equatable {
        case off
        case needsModel
        case downloading(Double)
        case indexing(done: Int, total: Int)
        case ready(unreadable: Int)
        case failed(String)
    }

    struct MoveProgress: Equatable {
        var done: Int
        var total: Int
    }

    private(set) var phase: Phase
    private(set) var isWorking = false
    private(set) var wrongPasswordAttempts = 0
    var message: String?
    private(set) var items: [VaultItem] = []
    var selection: Set<VaultItem.ID> = []
    var viewing: VaultItem.ID?
    private(set) var moveProgress: MoveProgress?
    var moveFailures: [VaultMoveFailure] = []
    private(set) var thumbnails: VaultThumbnails?
    private(set) var isLocking = false
    @ObservationIgnored var player: AVPlayer?
    private(set) var searchState: SearchState = .off
    var query = "" {
        didSet { if query != oldValue { runQuery() } }
    }
    private(set) var searchResult: VaultSearchResult? {
        didSet { keepOnlyVisibleItemsChosen() }
    }
    private(set) var isSearching = false
    var filter: VaultFilter = .all {
        didSet { keepOnlyVisibleItemsChosen() }
    }
    var videoOrder: VaultVideoOrder = .newest
    private(set) var durations: [VaultItem: Double] = [:]
    var mode: Mode = .library {
        didSet {
            guard mode != oldValue else { return }
            if mode == .duplicates { findDuplicates() }
            keepOnlyVisibleItemsChosen()
        }
    }
    private(set) var duplicateGroups: [VaultDuplicates.Group]? {
        didSet { keepOnlyVisibleItemsChosen() }
    }

    let disk: VaultDisk
    private var lockCount = 0
    private var moveTask: Task<Void, Never>?
    private var moveID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var searchEngine: VaultSearchEngine?
    private var indexTask: Task<Void, Never>?
    private var indexAgain = false
    private var queryTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private var digests: [VaultItem: Data] = [:]
    private static let typingPause: Duration = .milliseconds(250)

    init(location: VaultLocation = .standard, watchesSystem: Bool = true) {
        disk = VaultDisk(location: location)
        if disk.isOpen { disk.lockAndWait() }
        phase = disk.exists ? .locked : .setup
        if watchesSystem { watchSystem() }
    }

    var root: URL { disk.location.mountPoint }
    private var privateFolder: URL { root.appendingPathComponent(VaultLibrary.privateFolderName) }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func create(password: String, confirmation: String) async {
        guard !isWorking, !isLocking else { return }
        message = nil
        do {
            try VaultDisk.validateNewPassword(password, confirmation: confirmation)
        } catch {
            message = error.localizedDescription
            return
        }
        let locksBefore = lockCount
        await perform("Vault creation failed") {
            try await self.disk.create(password: password)
            Log.info("Vault created", category: VaultLog.category)
            self.phase = .locked
            try await self.disk.unlock(password: password)
            self.openUnlessLockedMeanwhile(since: locksBefore)
        }
    }

    func unlock(password: String) async {
        guard !isWorking, !isLocking, !password.isEmpty else { return }
        message = nil
        isWorking = true
        defer { isWorking = false }
        let locksBefore = lockCount
        do {
            try await disk.unlock(password: password)
            openUnlessLockedMeanwhile(since: locksBefore)
        } catch VaultError.wrongPassword {
            wrongPasswordAttempts += 1
            message = VaultError.wrongPassword.localizedDescription
        } catch {
            message = error.localizedDescription
            VaultLog.failure("Vault unlock failed", error)
        }
    }

    func finishOpening() {
        guard phase == .opening, !isLocking, disk.isOpen else { return }
        phase = .open
        addDebugFiles()
    }

    private func addDebugFiles() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--vault-debug-add"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        add([folder])
        #endif
    }

    func lock() async {
        guard !isLocking else { return }
        let engine = searchEngine
        let indexing = indexTask
        searchEngine = nil
        beginLocking()
        await indexing?.value
        await engine?.shutDown()
        await moveTask?.value
        clearOpenState()
        do {
            try await disk.lock()
        } catch {
            VaultLog.failure("Vault lock failed", error)
            disk.lockAndWait()
        }
        settleAfterLocking()
    }

    func lockImmediately() {
        beginLocking()
        clearOpenState()
        disk.lockAndWait()
        settleAfterLocking()
    }

    static let stillOpenMessage = "The vault couldn't be locked because something is still using a file in it. Close it and press Lock again."

    private func beginLocking() {
        lockCount += 1
        isLocking = true
        moveTask?.cancel()
        thumbnails?.gate.close()
        releasePlayer()
        stopSearch()
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func settleAfterLocking() {
        isLocking = false
        guard disk.isOpen else {
            if disk.exists { phase = .locked }
            return
        }
        Log.error("Vault still open after locking", category: VaultLog.category)
        message = Self.stillOpenMessage
        thumbnails = VaultThumbnails(vaultRoot: root)
        reload()
        phase = .open
        startSearch()
    }

    func changePassword(current: String, new: String, confirmation: String) async -> Bool {
        do {
            try VaultDisk.validateNewPassword(new, confirmation: confirmation)
            try await disk.changePassword(from: current, to: new)
            Log.info("Vault password changed", category: VaultLog.category)
            return true
        } catch {
            message = error.localizedDescription
            if !Self.isUserMistake(error) { VaultLog.failure("Vault password change failed", error) }
            return false
        }
    }

    func reload() {
        guard disk.isOpen else { return }
        items = VaultLibrary.items(in: root)
        selection.formIntersection(Set(items.map(\.id)))
        if let viewing, !items.contains(where: { $0.id == viewing }) { self.viewing = nil }
        loadDurations()
        VaultPlayable.prune(keeping: items, privateFolder: privateFolder)
        if mode == .duplicates { findDuplicates() }
    }

    func playableURL(for item: VaultItem) async -> URL {
        await VaultPlayable.url(for: item, privateFolder: privateFolder)
    }

    var visibleDuplicateGroups: [VaultDuplicates.Group]? {
        duplicateGroups.map { VaultDuplicates.filtered($0, by: filter) }
    }

    private func findDuplicates() {
        duplicateTask?.cancel()
        let snapshot = items
        let present = Set(snapshot)
        let known = digests.filter { present.contains($0.key) }
        duplicateTask = Task {
            let (groups, found) = await Task.detached(priority: .userInitiated) {
                var found = known
                let groups = VaultDuplicates.groups(in: snapshot) { item in
                    if let digest = found[item] { return digest }
                    let digest = try VaultMover.sha256(item.url)
                    found[item] = digest
                    return digest
                }
                return (groups, found)
            }.value
            guard !Task.isCancelled else { return }
            digests = found
            duplicateGroups = groups
        }
    }

    func keep(_ keeper: VaultItem, in group: VaultDuplicates.Group) async {
        await moveToTrash(VaultDuplicates.others(than: keeper, in: group))
    }

    func moveToTrash(_ doomed: [VaultItem]) async {
        var trashed: [VaultItem] = []
        for item in doomed {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                trashed.append(item)
                await thumbnails?.remove(item)
            } catch {
                VaultLog.failure("Vault trash failed", error, file: item.url)
            }
        }
        VaultPlayable.remove(trashed, privateFolder: privateFolder)
        let failed = doomed.count - trashed.count
        if failed > 0 { message = failed == 1 ? "1 item couldn't be moved to the Trash." : "\(failed) items couldn't be moved to the Trash." }
        selection.subtract(trashed.map(\.id))
        reload()
        await searchEngine?.remove(trashed)
        if !query.isEmpty { runQuery() }
    }

    private func loadDurations() {
        let present = Set(items)
        durations = durations.filter { present.contains($0.key) }
        let missing = items.filter { $0.kind == .video && durations[$0] == nil }
        durationTask?.cancel()
        guard !missing.isEmpty else { return }
        durationTask = Task {
            let found = await VaultBrowse.durations(of: missing)
            guard !Task.isCancelled else { return }
            durations.merge(found) { _, new in new }
        }
    }

    func add(_ urls: [URL]) {
        guard phase == .open, !isLocking, moveTask == nil else { return }
        let files = VaultMover.expand(urls)
        guard !files.isEmpty else { return }
        moveFailures = []
        moveProgress = MoveProgress(done: 0, total: files.count)
        let id = UUID()
        moveID = id
        moveTask = Task {
            for file in files {
                if Task.isCancelled || !disk.isOpen { break }
                do {
                    _ = try await VaultMover.move(file, into: root)
                } catch {
                    moveFailures.append(VaultMoveFailure(name: file.lastPathComponent, reason: error.localizedDescription))
                    if Self.isUnexpected(error) { VaultLog.failure("Vault move failed", error, file: file) }
                }
                moveProgress?.done += 1
                reload()
            }
            Log.info("Moved into vault", category: VaultLog.category,
                     ["count": String(files.count), "failed": String(moveFailures.count)])
            refreshIndex()
            guard moveID == id else { return }
            moveProgress = nil
            moveTask = nil
            moveID = nil
        }
    }

    func delete(_ ids: Set<VaultItem.ID>) async {
        let doomed = items.filter { ids.contains($0.id) }
        var failed = 0
        for item in doomed {
            do {
                try FileManager.default.removeItem(at: item.url)
                await thumbnails?.remove(item)
            } catch {
                failed += 1
                VaultLog.failure("Vault delete failed", error, file: item.url)
            }
        }
        if failed > 0 { message = failed == 1 ? "1 item couldn't be deleted." : "\(failed) items couldn't be deleted." }
        VaultPlayable.remove(doomed.filter { !FileManager.default.fileExists(atPath: $0.url.path) }, privateFolder: privateFolder)
        selection.subtract(ids)
        reload()
        await searchEngine?.remove(doomed.filter { !FileManager.default.fileExists(atPath: $0.url.path) })
        if !query.isEmpty { runQuery() }
    }

    func step(_ offset: Int) {
        guard let viewing, let next = VaultLibrary.neighbor(of: viewing, in: displayedItems, step: offset) else { return }
        self.viewing = next
    }

    var displayedItems: [VaultItem] {
        if mode == .duplicates { return (visibleDuplicateGroups ?? []).flatMap(\.copies) }
        guard !query.isEmpty, let searchResult else {
            return VaultBrowse.arranged(items, filter: filter, order: videoOrder, durations: durations)
        }
        let byPath = Dictionary(items.map { (searchEngine?.relativePath(of: $0.url) ?? $0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let ranked = searchResult.hits.compactMap { byPath[$0.path] }
        return VaultBrowse.arranged(ranked, filter: filter, order: .newest, durations: durations)
    }

    func lengthLabel(for item: VaultItem) -> String? {
        VaultBrowse.lengthLabel(for: item, durations: durations)
    }

    private func keepOnlyVisibleItemsChosen() {
        let visible = Set(displayedItems.map(\.id))
        if !selection.isEmpty { selection.formIntersection(visible) }
        if let viewing, !visible.contains(viewing) { self.viewing = nil }
    }

    var searchSections: (clear: [VaultItem], possible: [VaultItem])? {
        guard !query.isEmpty, let searchResult else { return nil }
        let shown = displayedItems
        let clearPaths = Set(searchResult.clearHits.map(\.path))
        let clear = shown.filter { clearPaths.contains(searchEngine?.relativePath(of: $0.url) ?? $0.name) }
        let clearIDs = Set(clear.map(\.id))
        return (clear, shown.filter { !clearIDs.contains($0.id) })
    }

    func downloadModel() {
        guard downloadTask == nil else { return }
        searchState = .downloading(0)
        downloadTask = Task {
            do {
                _ = try await VaultModelDownload.run { fraction in
                    Task { @MainActor [weak self] in
                        if case .downloading = self?.searchState { self?.searchState = .downloading(fraction) }
                    }
                }
                Log.info("Search model downloaded", category: VaultLog.category)
                downloadTask = nil
                if phase == .open || phase == .opening { startSearch() } else { searchState = .off }
            } catch {
                downloadTask = nil
                VaultLog.failure("Search model download failed", error)
                searchState = .failed("The download failed: \(error.localizedDescription)")
            }
        }
    }

    func retrySearch() {
        guard phase == .open, !isLocking else { return }
        if EmbeddingModel.locate() == nil { return downloadModel() }
        stopSearch()
        startSearch()
    }

    private func startSearch() {
        guard searchEngine == nil, !isLocking else { return }
        guard let model = EmbeddingModel.locate() else {
            if downloadTask == nil { searchState = .needsModel }
            return
        }
        searchEngine = VaultSearchEngine(root: root, model: model)
        refreshIndex()
    }

    private func stopSearch() {
        indexTask?.cancel()
        indexTask = nil
        queryTask?.cancel()
        queryTask = nil
        searchEngine?.close()
        searchEngine = nil
        indexAgain = false
        isSearching = false
        if downloadTask == nil { searchState = .off }
    }

    private func refreshIndex() {
        guard let engine = searchEngine else { return }
        guard indexTask == nil else {
            indexAgain = true
            return
        }
        indexTask = Task {
            repeat {
                indexAgain = false
                await index(with: engine)
            } while indexAgain && !Task.isCancelled && searchEngine === engine
            if searchEngine === engine { indexTask = nil }
        }
    }

    private func index(with engine: VaultSearchEngine) async {
        do {
            let pending = try await engine.pending(items)
            var done = 0
            var unreadable = 0
            for item in pending {
                guard !Task.isCancelled, searchEngine === engine else { return }
                searchState = .indexing(done: done, total: pending.count)
                do {
                    try await engine.index(item)
                } catch VaultSearchError.closed {
                    return
                } catch is CancellationError {
                    return
                } catch let error as VaultSearchError {
                    throw error
                } catch {
                    unreadable += 1
                    VaultLog.failure("Vault search indexing failed", error, file: item.url)
                }
                done += 1
                if !query.isEmpty { runQuery() }
            }
            await engine.finishIndexing()
            guard searchEngine === engine else { return }
            searchState = .ready(unreadable: unreadable)
            if !pending.isEmpty {
                Log.info("Vault indexed", category: VaultLog.category, ["count": String(pending.count)])
            }
        } catch VaultSearchError.closed {
            return
        } catch {
            guard searchEngine === engine else { return }
            VaultLog.failure("Vault search index failed", error)
            searchState = .failed(error.localizedDescription)
        }
    }

    private func runQuery() {
        queryTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine = searchEngine else {
            searchResult = nil
            isSearching = false
            return
        }
        isSearching = true
        queryTask = Task {
            try? await Task.sleep(for: Self.typingPause)
            guard !Task.isCancelled else { return }
            let names = Dictionary(items.map { (engine.relativePath(of: $0.url), $0.name) }, uniquingKeysWith: { first, _ in first })
            do {
                let result = try await engine.search(text, names: names)
                guard !Task.isCancelled, searchEngine === engine else { return }
                searchResult = result
            } catch VaultSearchError.closed {
                return
            } catch {
                VaultLog.failure("Vault search failed", error)
                message = "Search failed: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    static func isUnexpected(_ error: Error) -> Bool {
        guard let moveError = error as? VaultMoveError else { return true }
        switch moveError {
        case .copyDiffers, .unreadable, .originalKept: return true
        case .interrupted, .changedWhileMoving: return false
        case .unsupportedType, .insidePhotosLibrary, .notDownloaded, .alreadyInVault, .link: return false
        }
    }

    static func isUserMistake(_ error: Error) -> Bool {
        switch error as? VaultError {
        case .wrongPassword, .passwordTooShort, .passwordsDiffer: true
        default: false
        }
    }

    private func openUnlessLockedMeanwhile(since locksBefore: Int) {
        guard lockCount == locksBefore else {
            disk.lockAndWait()
            Log.info("Vault locked while it was opening", category: VaultLog.category)
            return
        }
        beginOpening()
    }

    private func beginOpening() {
        thumbnails = VaultThumbnails(vaultRoot: root)
        wrongPasswordAttempts = 0
        reload()
        phase = .opening
        startSearch()
    }

    private func clearOpenState() {
        viewing = nil
        selection = []
        items = []
        moveProgress = nil
        moveTask = nil
        moveID = nil
        releasePlayer()
        durationTask?.cancel()
        durationTask = nil
        durations = [:]
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateGroups = nil
        digests = [:]
        mode = .library
        query = ""
        searchResult = nil
        let old = thumbnails
        thumbnails = nil
        Task { await old?.forget() }
    }

    private func perform(_ failure: String, _ work: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            message = error.localizedDescription
            VaultLog.failure(failure, error)
        }
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockImmediately() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockImmediately() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockImmediately() }
        })
    }
}
