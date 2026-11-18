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
    private(set) var folderWithFilesLeftOutside: URL?
    private(set) var items: [VaultItem] = []
    var selection: Set<VaultItem.ID> = []
    var viewing: VaultItem.ID?
    var detailing: VaultItem.ID?
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
            selection = []
            if mode == .duplicates { findDuplicates() }
            keepOnlyVisibleItemsChosen()
        }
    }
    private(set) var duplicateGroups: [VaultDuplicates.Group]? {
        didSet { keepOnlyVisibleItemsChosen() }
    }
    private(set) var trash = VaultTrash.Summary()

    let disk: VaultDisk
    private var lockCount = 0
    private var moveTask: Task<Void, Never>?
    private var moveID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var searchEngine: VaultSearchEngine?
    private var indexTask: Task<Void, Never>?
    private var indexAgain = false
    private(set) var searchFailures: Set<VaultItem.ID> = []
    private var searchFirst: [VaultItem.ID] = []
    private var renamesInFlight: Set<VaultItem.ID> = []
    private var queryTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var duplicateTask: Task<Void, Never>?
    private var digests: [VaultItem: Data] = [:]
    private var looks: [VaultItem: VaultLook] = [:]
    private var lengthsInFlight: Set<VaultItem> = []
    private var unreadableLengths: Set<VaultItem> = []
    private var lengthTasks: [Task<Void, Never>] = []
    private var openGeneration = 0
    private var filesStillToMove: [URL] = []
    private(set) var ownsMount = false
    fileprivate var outsideCloseNotice: (duringImport: Bool, unconfirmed: Int)?
    private let anotherCopyIsRunning: @MainActor () -> Bool
    fileprivate var mayEject: Bool { ownsMount || !anotherCopyIsRunning() }
    @ObservationIgnored var moveFile: @Sendable (_ file: URL, _ vaultRoot: URL) async throws -> URL = { try await VaultMover.move($0, into: $1) }
    @ObservationIgnored private(set) var libraryReloads = 0
    private static let duplicatePause: Duration = .milliseconds(400)
    private static let typingPause: Duration = .milliseconds(250)

    init(location: VaultLocation, watchesSystem: Bool = true, tool: VaultTool = .system,
         anotherCopyIsRunning: @escaping @MainActor () -> Bool = VaultModel.anotherCopyOfThisAppIsRunning) {
        disk = VaultDisk(location: location, tool: tool)
        self.anotherCopyIsRunning = anotherCopyIsRunning
        if disk.isOpen, !anotherCopyIsRunning() { disk.lockAndWait() }
        phase = disk.exists ? .locked : .setup
        if watchesSystem { watchSystem() }
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
        let locksBefore = lockCount
        await perform("Vault creation failed") {
            try await self.disk.create(password: password)
            Log.info("Vault created", category: VaultLog.category)
            self.phase = .locked
            try await self.disk.unlock(password: password, ejectsIfItFails: !self.anotherCopyIsRunning())
            self.ownsMount = true
            self.openUnlessLockedMeanwhile(since: locksBefore)
        }
    }

    func unlock(password: String) async {
        guard !isWorking, !isLocking, !password.isEmpty else { return }
        clearDoorMessage()
        guard !disk.isOpen || mayEject else {
            message = Self.openInAnotherCopyMessage
            return
        }
        isWorking = true
        defer { isWorking = false }
        let locksBefore = lockCount
        do {
            try await disk.unlock(password: password, ejectsIfItFails: !anotherCopyIsRunning())
            ownsMount = true
            openUnlessLockedMeanwhile(since: locksBefore)
        } catch VaultError.wrongPassword {
            wrongPasswordAttempts += 1
            message = VaultError.wrongPassword.localizedDescription
        } catch {
            showDoorFailure(error)
            VaultLog.failure("Vault unlock failed", error)
        }
    }

    func finishOpening() {
        guard phase == .opening, !isLocking, disk.isOpen else { return }
        phase = .open
        addDebugFiles()
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
        if mayEject {
            do {
                try await disk.lock()
            } catch {
                VaultLog.failure("Vault lock failed", error)
                disk.lockAndWait()
            }
        }
        settleAfterLocking()
    }

    func lockImmediately() {
        beginLocking()
        clearOpenState()
        if mayEject { disk.lockAndWait() }
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
        guard disk.isOpen, mayEject else {
            ownsMount = false
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

    func reload() {
        guard disk.isOpen else { return }
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

    private func findDuplicates() {
        duplicateTask?.cancel()
        let generation = openGeneration
        duplicateTask = Task {
            try? await Task.sleep(for: Self.duplicatePause)
            guard !Task.isCancelled else { return }
            let snapshot = items
            let present = Set(snapshot)
            let lengths = await lengthsForDuplicates(of: snapshot)
            guard !Task.isCancelled, generation == openGeneration else { return }
            let unlooked = VaultDuplicates.lookCandidates(in: snapshot, durations: lengths).filter { looks[$0] == nil }
            let newLooks = await VaultLookReader.looks(of: unlooked, durations: lengths)
            guard !Task.isCancelled, generation == openGeneration else { return }
            looks.merge(newLooks) { _, new in new }
            let knownLooks = looks.filter { present.contains($0.key) }
            let known = digests.filter { present.contains($0.key) }
            let stop = StopFlag()
            let (groups, found) = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    var found = known
                    let groups = VaultDuplicates.groups(in: snapshot, digest: { item in
                        if let digest = found[item] { return digest }
                        guard !stop.isSet else { throw CancellationError() }
                        let digest = try VaultMover.sha256(item.url)
                        found[item] = digest
                        return digest
                    }, durations: lengths, looks: knownLooks)
                    return (groups, found)
                }.value
            } onCancel: { stop.set() }
            guard generation == openGeneration else { return }
            digests.merge(found) { _, new in new }
            guard !Task.isCancelled else { return }
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
        guard moveTask == nil else { return }
        let failures = VaultTrash.putBackAll(privateFolder: privateFolder, into: root)
        for (file, error) in failures { VaultLog.failure("Vault put back failed", error, file: file) }
        if !failures.isEmpty { message = failures.count == 1 ? "1 item couldn't be put back." : "\(failures.count) items couldn't be put back." }
        reload()
        refreshIndex()
    }

    func emptyTrash() {
        guard moveTask == nil else { return }
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
        guard phase == .open, !isLocking, moveTask == nil else { return }
        let files = VaultMover.expand(urls)
        guard !files.isEmpty else { return }
        moveFailures = []
        filesStillToMove = files
        guard !lockIfClosedFromOutside() else { return }
        moveProgress = MoveProgress(done: 0, total: files.count)
        let id = UUID()
        moveID = id
        moveTask = Task { [moveFile] in
            for file in files {
                if Task.isCancelled || !disk.isOpen { break }
                do {
                    let moved = try await moveFile(file, root)
                    if moveID == id { showMovedIn(moved) } else { correctReportIfMovedAfterAll(file) }
                } catch {
                    guard moveID == id else { break }
                    moveFailures.append(VaultMoveFailure(name: file.lastPathComponent, reason: error.localizedDescription))
                    if Self.isUnexpected(error) { VaultLog.failure("Vault move failed", error, file: file) }
                }
                guard moveID == id else { break }
                filesStillToMove.removeAll { $0 == file }
                moveProgress?.done += 1
            }
            Log.info("Moved into vault", category: VaultLog.category,
                     ["count": String(files.count), "failed": String(moveFailures.count)])
            guard moveID == id, !lockIfClosedFromOutside() else { return }
            filesStillToMove = []
            if !isLocking { reload() }
            refreshIndex()
            moveProgress = nil
            moveTask = nil
            moveID = nil
        }
    }

    private func showMovedIn(_ url: URL) {
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
        searchFirst = []
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
            var queue = pending
            var done = 0
            var unreadable = 0
            while !queue.isEmpty {
                guard !Task.isCancelled, searchEngine === engine else { return }
                searchState = .indexing(done: done, total: pending.count)
                let item = queue.remove(at: queue.firstIndex { searchFirst.contains($0.id) } ?? 0)
                searchFirst.removeAll { $0 == item.id }
                guard items.contains(where: { $0.id == item.id }) else { continue }
                do {
                    try await engine.index(item)
                    searchFailures.remove(item.id)
                } catch VaultSearchError.closed {
                    return
                } catch is CancellationError {
                    return
                } catch let error as VaultSearchError {
                    throw error
                } catch where !FileManager.default.fileExists(atPath: item.url.path) {
                    continue
                } catch {
                    unreadable += 1
                    searchFailures.insert(item.id)
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

    private func openUnlessLockedMeanwhile(since locksBefore: Int) {
        guard lockCount == locksBefore else {
            disk.lockAndWait()
            ownsMount = disk.isOpen
            Log.info("Vault locked while it was opening", category: VaultLog.category)
            return
        }
        beginOpening()
    }

    private func beginOpening() {
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
        moveProgress = nil
        moveTask = nil
        moveID = nil
        filesStillToMove = []
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
        digests = [:]
        searchFailures = []
        looks = [:]
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
            showDoorFailure(error)
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
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeDidUnmount(volume) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.lockIfClosedFromOutside() }
        })
    }
}

extension VaultModel {
    static let finishedAsVaultClosedReason = "It finished moving just as the vault closed. Check it after you unlock."

    static func closedFromOutsideMessage(duringImport: Bool, unconfirmed: Int) -> String {
        var notice = "The vault was closed from outside Toolbox."
        if duringImport { notice += " Files that had not been moved yet are still where they were." }
        if unconfirmed > 0 {
            notice += " \(unconfirmed == 1 ? "1 file" : "\(unconfirmed) files") finished moving just as the vault closed; "
                + "check \(unconfirmed == 1 ? "it" : "them") after you unlock."
        }
        return notice + " Unlock to continue."
    }

    static func isUnexpected(_ error: Error) -> Bool {
        guard let moveError = error as? VaultMoveError else { return true }
        switch moveError {
        case .copyDiffers, .unreadable, .vaultNotOpen, .notSaved, .originalKept: return true
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

    static let openInAnotherCopyMessage = "The vault is open in another copy of Toolbox. Lock it there first."

    static func anotherCopyOfThisAppIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0 != .current }
    }

    func volumeDidUnmount(_ volume: URL?) {
        guard volume?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { return }
        lockIfClosedFromOutside()
    }

    @discardableResult
    func lockIfClosedFromOutside() -> Bool {
        guard phase == .open || phase == .opening, !isLocking, !disk.isOpen else { return false }
        let duringImport = moveTask != nil || !filesStillToMove.isEmpty
        let unconfirmed = filesStillToMove.filter { !FileManager.default.fileExists(atPath: $0.path) }
        Log.warning("Vault closed from outside the app", category: VaultLog.category,
                    ["still_to_move": String(filesStillToMove.count), "unconfirmed": String(unconfirmed.count)])
        moveFailures += filesStillToMove.map {
            VaultMoveFailure(name: $0.lastPathComponent,
                             reason: unconfirmed.contains($0) ? Self.finishedAsVaultClosedReason : VaultMoveError.vaultNotOpen.localizedDescription)
        }
        outsideCloseNotice = (duringImport, unconfirmed.count)
        beginLocking()
        clearOpenState()
        disk.removeEmptyMountPoint()
        ownsMount = false
        isLocking = false
        phase = disk.exists ? .locked : .setup
        message = Self.closedFromOutsideMessage(duringImport: duringImport, unconfirmed: unconfirmed.count)
        return true
    }

    // The move in flight when the eject was noticed can still finish: its copy was already checked and saved to the disk.
    fileprivate func correctReportIfMovedAfterAll(_ file: URL) {
        let kept = VaultMoveError.vaultNotOpen.localizedDescription
        guard !FileManager.default.fileExists(atPath: file.path), let notice = outsideCloseNotice,
              let listed = moveFailures.firstIndex(where: { $0.name == file.lastPathComponent && $0.reason == kept }) else { return }
        moveFailures[listed] = VaultMoveFailure(name: file.lastPathComponent, reason: Self.finishedAsVaultClosedReason)
        let noticeShown = message == Self.closedFromOutsideMessage(duringImport: notice.duringImport, unconfirmed: notice.unconfirmed)
        outsideCloseNotice = (notice.duringImport, notice.unconfirmed + 1)
        if noticeShown { message = Self.closedFromOutsideMessage(duringImport: notice.duringImport, unconfirmed: notice.unconfirmed + 1) }
    }

    fileprivate func addDebugFiles() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--vault-debug-add"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        add([folder])
        #endif
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
    func keep(_ keeper: VaultItem, in group: VaultDuplicates.Group) async {
        guard moveTask == nil else { return }
        guard VaultDuplicates.isStillIntact(group, keeping: keeper) else {
            message = "These copies changed since they were compared. Look again before choosing."
            findDuplicates()
            return
        }
        await moveToTrash(VaultDuplicates.others(than: keeper, in: group))
    }

    func trashChosenCopies(_ chosen: Set<VaultItem.ID>) async {
        guard moveTask == nil, let groups = visibleDuplicateGroups else { return }
        guard VaultDuplicates.groupsWithEveryCopy(of: chosen, in: groups).isEmpty else {
            message = "Leave at least one copy of each set unselected."
            return
        }
        let touched = groups.filter { group in group.copies.contains { chosen.contains($0.id) } }
        let stillIntact = touched.allSatisfy { group in
            group.copies.first { !chosen.contains($0.id) }.map { VaultDuplicates.isStillIntact(group, keeping: $0) } ?? false
        }
        guard stillIntact else {
            message = "These copies changed since they were compared. Look again before choosing."
            findDuplicates()
            return
        }
        await moveToTrash(VaultDuplicates.chosenCopies(chosen, in: touched))
    }

    func chooseExtraCopies() {
        guard let groups = visibleDuplicateGroups else { return }
        selection = Set(VaultDuplicates.extraCopies(in: groups).map(\.id))
    }

    fileprivate func lengthsForDuplicates(of snapshot: [VaultItem]) async -> [VaultItem: Double] {
        let missing = snapshot.filter { $0.kind == .video && durations[$0] == nil && !unreadableLengths.contains($0) }
        guard !missing.isEmpty else { return durations }
        let found = await VaultBrowse.durations(of: missing)
        durations.merge(found) { _, new in new }
        return durations
    }

    func rename(_ item: VaultItem, to typed: String) async throws -> VaultItem {
        guard phase == .open, moveTask == nil else { return item }
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
        if let digest = digests.removeValue(forKey: item) { digests[renamed] = digest }
        if let look = looks.removeValue(forKey: item) { looks[renamed] = look }
        if searchFailures.remove(item.id) != nil { searchFailures.insert(renamed.id) }
        searchFirst = searchFirst.map { $0 == item.id ? renamed.id : $0 }
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

    func addToSearch(_ item: VaultItem) {
        guard phase == .open else { return }
        searchFailures.remove(item.id)
        if searchEngine == nil { retrySearch() }
        searchFirst.removeAll { $0 == item.id }
        searchFirst.insert(item.id, at: 0)
        refreshIndex()
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
