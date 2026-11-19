import AppKit
import AVFoundation
import VaultSearch
import Observation

@MainActor
@Observable
final class VaultModel {
    private(set) var phase: Phase
    var isWorking = false
    private(set) var wrongPasswordAttempts = 0
    var message: String?
    private(set) var folderWithFilesLeftOutside: URL?
    private(set) var items: [VaultItem] = []
    var selection: Set<VaultItem.ID> = []
    var viewing: VaultItem.ID?
    var detailing: VaultItem.ID?
    var moveProgress: MoveProgress? { moves.progress }
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
            selection = []
            if mode == .duplicates { findDuplicates() }
            keepOnlyVisibleItemsChosen()
        }
    }
    private(set) var duplicateGroups: [VaultDuplicates.Group]? {
        didSet { keepOnlyVisibleItemsChosen() }
    }
    private(set) var trash = VaultTrash.Summary()

    let door: VaultDoor
    let passwordKeeper: VaultPasswordKeeper
    var usesTouchID: Bool {
        didSet { if !usesTouchID { passwordKeeper.forget() } }
    }
    @ObservationIgnored var searchWaitLimit: Duration = .seconds(180)
    var disk: VaultDisk { door.disk }
    private(set) var lockCount = 0
    private var lockInFlight: Task<Void, Never>?
    private(set) var lastLockFailure: String?
    /// Download Video opened the vault and has not seen it locked since, so it is that send's to lock, retries included.
    var openedForDownloads = false
    @ObservationIgnored private(set) lazy var quitGuard = VaultQuitGuard(self)
    var moves = VaultMoveTracker()
    private var observers: [NSObjectProtocol] = []
    private var searchEngine: VaultSearchEngine?
    private var indexTask: Task<Void, Never>?
    private var indexAgain = false
    private(set) var searchFailures: Set<VaultItem.ID> = []
    private var indexQueue = VaultIndexQueue()
    let searchWaiters = VaultSearchWaiters()
    private var renamesInFlight: Set<VaultItem.ID> = []
    private var queryTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private let duplicateFinder = VaultDuplicateFinder()
    private var lengthsInFlight: Set<VaultItem> = []
    private var unreadableLengths: Set<VaultItem> = []
    private var lengthTasks: [Task<Void, Never>] = []
    private var openGeneration = 0
    @ObservationIgnored var moveFile: @Sendable (_ file: URL, _ vaultRoot: URL) async throws -> URL = { try await VaultMover.move($0, into: $1) }
    @ObservationIgnored private(set) var libraryReloads = 0
    private static let duplicatePause: Duration = .milliseconds(400)
    private static let typingPause: Duration = .milliseconds(250)

    init(location: VaultLocation, watchesSystem: Bool = true, tool: VaultTool = .system, bounds: VaultDoor.Bounds = VaultDoor.Bounds(),
         anotherCopyIsRunning: @escaping @Sendable () -> Bool = VaultDoor.anotherCopyOfThisAppIsRunning,
         passwordKeeper: VaultPasswordKeeper? = nil) {
        door = VaultDoor(location: location, tool: tool, bounds: bounds, anotherCopyIsRunning: anotherCopyIsRunning)
        self.passwordKeeper = passwordKeeper ?? VaultTouchIDKey(location: location)
        usesTouchID = self.passwordKeeper.hasPassword
        phase = door.disk.exists ? .locked : .setup
        if door.state == .openElsewhere { closeLeftoverFromACrash() }
        if watchesSystem { observers = watchSystem() }
    }

    var root: URL { disk.location.mountPoint }
    private var privateFolder: URL { root.appendingPathComponent(VaultLibrary.privateFolderName) }

    func create(password: String, confirmation: String) async {
        guard !isWorking, !isLocking else { return }
        clearDoorMessage()
        do {
            try VaultDisk.validateNewPassword(password, confirmation: confirmation)
        } catch {
            message = error.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        let locksBefore = lockCount
        if let refusal = await door.create(password: password) {
            showDoorFailure(refusal)
            return VaultLog.failure("Vault creation failed", refusal)
        }
        Log.info("Vault created", category: VaultLog.category)
        quitGuard.forgetRefusal()
        phase = .locked
        guard lockCount == locksBefore else { return }
        await open(password: password, since: locksBefore)
    }

    func unlock(password: String) async {
        guard !isWorking, !isLocking, !password.isEmpty else { return }
        clearDoorMessage()
        isWorking = true
        defer { isWorking = false }
        await open(password: password, since: lockCount)
    }

    private func open(password: String, since locksBefore: Int) async {
        let outcome = await door.unlock(password: password)
        switch outcome {
        case .opened where lockCount == locksBefore:
            openedForDownloads = false
            beginOpening()
            rememberForTouchID(password)
        case .opened, .lockedMeanwhile:
            Log.info("Vault locked while it was opening", category: VaultLog.category)
        case .refused(.wrongPassword):
            wrongPasswordAttempts += 1
            message = VaultError.wrongPassword.localizedDescription
        case .refused(let refusal):
            showDoorFailure(refusal)
            VaultLog.failure("Vault unlock failed", refusal)
        }
        if case .refused = outcome, door.state == .open { message = VaultNotices.leftMountedByFailedUnlock }
    }

    func finishOpening() {
        guard phase == .opening, !isLocking, door.state == .open else { return }
        phase = .open
        addDebugFiles()
    }

    func lock() async {
        await lockImmediately().value
    }

    /// The vault looks locked at once; the door ejects in the background and `settle` records how it went.
    @discardableResult
    func lockImmediately() -> Task<Void, Never> {
        if let lockInFlight { return lockInFlight }
        let engine = searchEngine
        let indexing = indexTask
        let moving = moves.task
        searchEngine = nil
        beginLocking()
        let locking = Task {
            await indexing?.value
            await engine?.shutDown()
            await moving?.value
            settle(await door.lock())
        }
        lockInFlight = locking
        return locking
    }

    fileprivate func beginLocking() {
        lockCount += 1
        isLocking = true
        door.interruptUnlock()
        moves.task?.cancel()
        thumbnails?.gate.close()
        stopSearch()
        clearOpenState()
        if phase == .open || phase == .opening { phase = .locked }
    }

    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    fileprivate func settle(_ outcome: VaultDoor.LockOutcome) {
        lockInFlight = nil
        isLocking = false
        guard case .stillMounted(let reason) = outcome else {
            lastLockFailure = nil
            openedForDownloads = false
            if phase != .setup || disk.exists { phase = disk.exists ? .locked : .setup }
            return
        }
        lastLockFailure = reason
        Log.error("Vault still open after locking", category: VaultLog.category)
        message = VaultNotices.stillOpen
        thumbnails = VaultThumbnails(vaultRoot: root)
        phase = .open
        reload()
        startSearch()
    }

    private func closeLeftoverFromACrash() {
        isLocking = true
        lockInFlight = Task {
            if case .stillMounted(let reason) = await door.recoverAtLaunch() {
                lastLockFailure = reason
                message = VaultNotices.leftoverStillMounted
            }
            lockInFlight = nil
            isLocking = false
        }
    }

    func reload() {
        guard door.state == .open else { return }
        libraryReloads += 1
        items = VaultLibrary.items(in: root)
        selection.formIntersection(Set(items.map(\.id)))
        if let viewing, !items.contains(where: { $0.id == viewing }) { self.viewing = nil }
        loadDurations()
        VaultPlayable.prune(keeping: items, privateFolder: privateFolder)
        trash = VaultTrash.summary(in: privateFolder)
        if mode == .duplicates { findDuplicates() }
    }

    func playableURL(for item: VaultItem) async -> URL {
        await VaultPlayable.url(for: item, privateFolder: privateFolder)
    }

    var visibleDuplicateGroups: [VaultDuplicates.Group]? {
        duplicateGroups.map { VaultDuplicates.filtered($0, by: filter) }
    }

    func findDuplicates() {
        duplicateTask?.cancel()
        let generation = openGeneration
        duplicateTask = Task {
            try? await Task.sleep(for: Self.duplicatePause)
            guard !Task.isCancelled else { return }
            let snapshot = items
            let lengths = await lengthsForDuplicates(of: snapshot)
            guard !Task.isCancelled, generation == openGeneration else { return }
            guard let groups = await duplicateFinder.groups(in: snapshot, lengths: lengths) else { return }
            duplicateGroups = groups
        }
    }

    func moveToTrash(_ doomed: [VaultItem]) async {
        var trashed: [VaultItem] = []
        for item in doomed {
            do {
                try VaultTrash.move(item.url, privateFolder: privateFolder)
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

    func putBackTrash() {
        guard !moves.isRunning else { return }
        let failures = VaultTrash.putBackAll(privateFolder: privateFolder, into: root)
        for (file, error) in failures { VaultLog.failure("Vault put back failed", error, file: file) }
        if !failures.isEmpty { message = failures.count == 1 ? "1 item couldn't be put back." : "\(failures.count) items couldn't be put back." }
        reload()
        refreshIndex()
    }

    func emptyTrash() {
        guard !moves.isRunning else { return }
        let failures = VaultTrash.empty(privateFolder: privateFolder)
        for (file, error) in failures { VaultLog.failure("Vault empty trash failed", error, file: file) }
        if !failures.isEmpty { message = failures.count == 1 ? "1 item couldn't be deleted." : "\(failures.count) items couldn't be deleted." }
        trash = VaultTrash.summary(in: privateFolder)
    }

    private func loadDurations() {
        let present = Set(items)
        durations = durations.filter { present.contains($0.key) }
        unreadableLengths.formIntersection(present)
        let missing = items.filter {
            $0.kind == .video && durations[$0] == nil && !lengthsInFlight.contains($0) && !unreadableLengths.contains($0)
        }
        guard !missing.isEmpty else { return }
        lengthsInFlight.formUnion(missing)
        let generation = openGeneration
        lengthTasks.append(Task {
            let found = await VaultBrowse.durations(of: missing)
            guard generation == openGeneration else { return }
            lengthsInFlight.subtract(missing)
            durations.merge(found) { _, new in new }
            unreadableLengths.formUnion(missing.filter { found[$0] == nil })
        })
    }

    func add(_ urls: [URL]) {
        guard phase == .open, !isLocking else { return }
        guard !moves.isRunning else {
            message = VaultMoveError.busy.localizedDescription
            return
        }
        let files = VaultMover.expand(urls)
        guard !files.isEmpty else { return }
        moveFailures = []
        let id = moves.begin(files)
        guard !lockIfClosedFromOutside() else { return }
        moves.task = Task { [moveFile] in
            for file in files {
                if Task.isCancelled || !disk.isOpen { break }
                do {
                    let moved = try await moveFile(file, root)
                    if moves.isCurrent(id) { showMovedIn(moved) } else { correctReportIfMovedAfterAll(file) }
                } catch {
                    guard moves.isCurrent(id) else { break }
                    moveFailures.append(VaultMoveFailure(name: file.lastPathComponent, reason: error.localizedDescription))
                    if VaultNotices.isUnexpected(error) { VaultLog.failure("Vault move failed", error, file: file) }
                }
                guard moves.isCurrent(id) else { break }
                moves.settled(file)
            }
            Log.info("Moved into vault", category: VaultLog.category,
                     ["count": String(files.count), "failed": String(moveFailures.count)])
            guard moves.isCurrent(id), !lockIfClosedFromOutside() else { return }
            if !isLocking { reload() }
            refreshIndex()
            moves.end()
        }
    }

    func showMovedIn(_ url: URL) {
        guard !isLocking, let item = VaultLibrary.item(movedTo: url) else { return }
        items = VaultLibrary.inserting(item, into: items)
        if item.kind == .video { loadDurations() }
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

    func startSearch() {
        guard searchEngine == nil, !isLocking else { return }
        guard let model = EmbeddingModel.locate() else {
            if downloadTask == nil { searchState = .needsModel }
            return
        }
        searchEngine = VaultSearchEngine(root: root, model: model)
        refreshIndex()
    }

    private func stopSearch() {
        searchWaiters.answerAll(searchable: false)
        indexTask?.cancel()
        indexTask = nil
        queryTask?.cancel()
        queryTask = nil
        searchEngine?.close()
        searchEngine = nil
        indexAgain = false
        indexQueue.clear()
        isSearching = false
        if downloadTask == nil { searchState = .off }
    }

    func refreshIndex() {
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
            guard searchEngine === engine else { return }
            await searchWaiters.answerEach { id in
                guard let item = items.first(where: { $0.id == id }) else { return false }
                return (try? await engine.coverage(of: item)) != nil
            }
            guard searchEngine === engine else { return }
            indexTask = nil
            if indexAgain { refreshIndex() }
        }
    }

    private func index(with engine: VaultSearchEngine) async {
        do {
            let pending = try await engine.pending(items)
            var queue = pending
            var done = 0
            var unreadable = 0
            while let item = indexQueue.next(from: &queue, in: items, gone: { searchWaiters.answer($0, searchable: false) }) {
                guard !Task.isCancelled, searchEngine === engine else { return }
                searchState = .indexing(done: done, total: max(pending.count, done + 1))
                indexQueue.remove(item.id)
                guard items.contains(where: { $0.id == item.id }) else { continue }
                do {
                    try await engine.index(item)
                    searchFailures.remove(item.id)
                    searchWaiters.answer(item.id, searchable: true)
                } catch VaultSearchError.closed {
                    return
                } catch is CancellationError {
                    return
                } catch let error as VaultSearchError {
                    throw error
                } catch where !FileManager.default.fileExists(atPath: item.url.path) {
                    searchWaiters.answer(item.id, searchable: false)
                    continue
                } catch {
                    unreadable += 1
                    searchFailures.insert(item.id)
                    searchWaiters.answer(item.id, searchable: false)
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
            guard searchEngine === engine, !lockIfClosedFromOutside() else { return }
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
                guard !lockIfClosedFromOutside() else { return }
                VaultLog.failure("Vault search failed", error)
                message = "Search failed: \(error.localizedDescription)"
            }
            isSearching = false
        }
    }

    func beginOpening() {
        VaultPlayable.removeUnfinishedCopies(privateFolder: privateFolder)
        thumbnails = VaultThumbnails(vaultRoot: root)
        wrongPasswordAttempts = 0
        reload()
        phase = .opening
        startSearch()
    }

    private func clearOpenState() {
        viewing = nil
        detailing = nil
        selection = []
        items = []
        moves.end()
        releasePlayer()
        openGeneration += 1
        lengthTasks.forEach { $0.cancel() }
        lengthTasks = []
        durations = [:]
        lengthsInFlight = []
        unreadableLengths = []
        trash = VaultTrash.Summary()
        duplicateTask?.cancel()
        duplicateTask = nil
        duplicateGroups = nil
        duplicateFinder.forget()
        searchFailures = []
        mode = .library
        query = ""
        searchResult = nil
        let old = thumbnails
        thumbnails = nil
        Task { await old?.forget() }
    }

}

extension VaultModel {
    /// Sleep cannot wait on the main actor, so it blocks on the door's own answer for at most the door's lock bound.
    func lockBeforeSleep() {
        if lockInFlight == nil { beginLocking() } else { door.interruptUnlock() }
        let pending = door.startLock()
        if pending.wait(upTo: door.bounds.lock) == nil {
            Log.error("Mac went to sleep before the vault locked", category: VaultLog.category,
                      ["reason": VaultNotices.whyNotLocked(during: door.unfinishedWrite, failure: lastLockFailure)])
        }
        if lockInFlight == nil { lockInFlight = Task { settle(await pending.value()) } }
    }

    @discardableResult
    func lockIfClosedFromOutside() -> Bool {
        guard phase == .open || phase == .opening, !isLocking, door.noticeOutsideEject() else { return false }
        let close = moves.closedFromOutside()
        Log.warning("Vault closed from outside the app", category: VaultLog.category,
                    ["still_to_move": String(close.stillToMove), "unconfirmed": String(close.unconfirmed)])
        moveFailures += close.failures
        openedForDownloads = false
        beginLocking()
        isLocking = false
        phase = disk.exists ? .locked : .setup
        message = close.notice
        return true
    }

    func correctReportIfMovedAfterAll(_ file: URL) {
        guard let correction = moves.correction(for: file, among: moveFailures) else { return }
        moveFailures[correction.listed] = correction.failure
        if message == correction.noticeBefore { message = correction.notice }
    }

    fileprivate func clearDoorMessage() {
        message = nil
        folderWithFilesLeftOutside = nil
    }

    fileprivate func showDoorFailure(_ error: Error) {
        message = error.localizedDescription
        if case VaultError.filesLeftOutside = error { folderWithFilesLeftOutside = disk.location.mountPoint }
    }
}

extension VaultModel {
    fileprivate func lengthsForDuplicates(of snapshot: [VaultItem]) async -> [VaultItem: Double] {
        let missing = snapshot.filter { $0.kind == .video && durations[$0] == nil && !unreadableLengths.contains($0) }
        guard !missing.isEmpty else { return durations }
        let found = await VaultBrowse.durations(of: missing)
        durations.merge(found) { _, new in new }
        return durations
    }

    func rename(_ item: VaultItem, to typed: String) async throws -> VaultItem {
        guard phase == .open, !moves.isRunning else { return item }
        guard let target = try VaultRename.destination(for: typed, renaming: item).get() else { return item }
        do {
            try VaultRename.move(item, to: target)
        } catch {
            VaultLog.failure("Vault rename failed", error, file: item.url)
            throw error
        }
        let renamed = VaultItem(url: target, kind: item.kind, added: item.added, bytes: item.bytes)
        VaultPlayable.carryOver(from: item, to: renamed, privateFolder: privateFolder)
        if let seconds = durations.removeValue(forKey: item) { durations[renamed] = seconds }
        duplicateFinder.carry(from: item, to: renamed)
        if searchFailures.remove(item.id) != nil { searchFailures.insert(renamed.id) }
        indexQueue.carry(from: item.id, to: renamed.id)
        searchWaiters.carry(from: item.id, to: renamed.id)
        if selection.remove(item.id) != nil { selection.insert(renamed.id) }
        if viewing == item.id { viewing = renamed.id }
        if detailing == item.id { detailing = renamed.id }
        renamesInFlight.insert(renamed.id)
        defer { renamesInFlight.remove(renamed.id) }
        reload()
        await thumbnails?.carryOver(from: item, to: renamed)
        do {
            try await searchEngine?.rename(item.url, to: target)
        } catch {
            VaultLog.failure("Vault search rename failed", error, file: target)
        }
        refreshIndex()
        if !query.isEmpty { runQuery() }
        return items.first { $0.id == renamed.id } ?? renamed
    }

    func searchStatus(of item: VaultItem) async -> VaultSearchStatus {
        switch searchState {
        case .needsModel, .downloading: return .needsModel
        case .failed(let reason): return .off(reason)
        case .off: return .off("Search is starting.")
        case .indexing, .ready: break
        }
        guard let engine = searchEngine else { return .off("Search is starting.") }
        if renamesInFlight.contains(item.id) { return .checking }
        if let coverage = try? await engine.coverage(of: item) {
            return .indexed(picture: coverage.segments[.image, default: 0] > 0, sound: coverage.segments[.audio, default: 0] > 0)
        }
        if indexTask != nil && !searchFailures.contains(item.id) { return .adding }
        return searchFailures.contains(item.id) ? .failed : .notIndexed
    }

    var isSearchRunning: Bool { searchEngine != nil }

    func putFirstInIndex(_ item: VaultItem) {
        searchFailures.remove(item.id)
        indexQueue.putFirst(item.id)
    }

    func addToSearch(_ item: VaultItem) {
        guard phase == .open else { return }
        if searchEngine == nil { retrySearch() }
        putFirstInIndex(item)
        refreshIndex()
    }
}
