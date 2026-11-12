import AppKit
import Observation

@MainActor
@Observable
final class VaultModel {
    enum Phase: Equatable { case setup, locked, opening, open }

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

    let disk: VaultDisk
    private var moveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(location: VaultLocation = .standard, watchesSystem: Bool = true) {
        disk = VaultDisk(location: location)
        if disk.isOpen { disk.lockAndWait() }
        phase = disk.exists ? .locked : .setup
        if watchesSystem { watchSystem() }
    }

    var root: URL { disk.location.mountPoint }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    func create(password: String, confirmation: String) async {
        message = nil
        do {
            try VaultDisk.validateNewPassword(password, confirmation: confirmation)
        } catch {
            message = error.localizedDescription
            return
        }
        await perform("Vault creation failed") {
            try await self.disk.create(password: password)
            try await self.disk.unlock(password: password)
            Log.info("Vault created", category: VaultLog.category)
            self.beginOpening()
        }
    }

    func unlock(password: String) async {
        message = nil
        guard !password.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await disk.unlock(password: password)
            beginOpening()
        } catch VaultError.wrongPassword {
            wrongPasswordAttempts += 1
            message = VaultError.wrongPassword.localizedDescription
        } catch {
            message = error.localizedDescription
            VaultLog.failure("Vault unlock failed", error)
        }
    }

    func finishOpening() {
        guard phase == .opening else { return }
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
        moveTask?.cancel()
        await moveTask?.value
        clearOpenState()
        do {
            try await disk.lock()
        } catch {
            VaultLog.failure("Vault lock failed", error)
            disk.lockAndWait()
        }
        if disk.exists { phase = .locked }
    }

    func lockImmediately() {
        moveTask?.cancel()
        clearOpenState()
        disk.lockAndWait()
        if disk.exists { phase = .locked }
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
    }

    func add(_ urls: [URL]) {
        guard phase == .open, moveTask == nil else { return }
        let files = VaultMover.expand(urls)
        guard !files.isEmpty else { return }
        moveFailures = []
        moveProgress = MoveProgress(done: 0, total: files.count)
        moveTask = Task {
            for file in files {
                if Task.isCancelled { break }
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
            moveProgress = nil
            moveTask = nil
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
        selection.subtract(ids)
        reload()
    }

    func step(_ offset: Int) {
        guard let viewing, let next = VaultLibrary.neighbor(of: viewing, in: items, step: offset) else { return }
        self.viewing = next
    }

    static func isUnexpected(_ error: Error) -> Bool {
        guard let moveError = error as? VaultMoveError else { return true }
        switch moveError {
        case .copyDiffers, .unreadable, .originalKept: return true
        case .unsupportedType, .insidePhotosLibrary, .notDownloaded, .alreadyInVault: return false
        }
    }

    static func isUserMistake(_ error: Error) -> Bool {
        switch error as? VaultError {
        case .wrongPassword, .passwordTooShort, .passwordsDiffer: true
        default: false
        }
    }

    private func beginOpening() {
        thumbnails = VaultThumbnails(vaultRoot: root)
        wrongPasswordAttempts = 0
        reload()
        phase = .opening
    }

    private func clearOpenState() {
        viewing = nil
        selection = []
        items = []
        moveProgress = nil
        moveTask = nil
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
