import AppKit

/// The one owner of the vault's disk image: every create, unlock, lock, eject and password change runs here, one at a time.
///
/// A class with lock-guarded state and a chain of operations, not an actor: an actor lets a second call in at every
/// `await`, so two ejects could overlap, and sleep needs an answer it can wait for without the main actor.
final class VaultDoor: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case closed
        case mounting
        case open
        case closing
        case openElsewhere
    }

    enum LockOutcome: Equatable, Sendable {
        case locked
        case stillMounted(reason: String)
        case notOurs
    }

    enum UnlockOutcome: Equatable, Sendable {
        case opened
        case lockedMeanwhile
        case refused(VaultError)
    }

    struct Bounds: Equatable, Sendable {
        var attach: TimeInterval = 60
        var lockStep: TimeInterval = 6
        /// How long Shell gives a program it stopped before killing it.
        var stopGrace: TimeInterval = Shell.secondsFromTerminateToKill

        /// Longest a lock can take once it has started: the attach it interrupts is killed, then an eject and a forced detach each run out.
        var lock: TimeInterval { stopGrace + 2 * (lockStep + stopGrace) }
    }

    /// The answer to a lock that was started without waiting for it. Sleep blocks on it from the main thread.
    final class PendingLock: @unchecked Sendable {
        private let settled = NSCondition()
        private var outcome: LockOutcome?
        fileprivate(set) var task: Task<LockOutcome, Never>?

        fileprivate func settle(_ outcome: LockOutcome) {
            settled.lock()
            self.outcome = outcome
            settled.broadcast()
            settled.unlock()
        }

        func wait(upTo seconds: TimeInterval) -> LockOutcome? {
            let deadline = Date(timeIntervalSinceNow: seconds)
            settled.lock()
            defer { settled.unlock() }
            while outcome == nil, settled.wait(until: deadline) {}
            return outcome
        }

        func value() async -> LockOutcome { await task?.value ?? .locked }
    }

    static let maximumSize = "2T"
    static let volumeName = "Vault"
    static let lockFileName = "Vault.lock"

    let disk: VaultDisk
    let bounds: Bounds
    private let tool: VaultTool
    private let anotherCopyIsRunning: @Sendable () -> Bool
    private let guardLock = NSLock()
    private var current: State
    private var lockRequests = 0
    private var attaching: Task<Shell.Result, Error>?
    private var lastOperation: Task<Void, Never>?
    private var ownership: Int32?

    init(location: VaultLocation, tool: VaultTool = .system, bounds: Bounds = Bounds(),
         anotherCopyIsRunning: @escaping @Sendable () -> Bool = VaultDoor.anotherCopyOfThisAppIsRunning) {
        disk = VaultDisk(location: location)
        self.tool = tool
        self.bounds = bounds
        self.anotherCopyIsRunning = anotherCopyIsRunning
        current = disk.isOpen ? .openElsewhere : .closed
    }

    deinit {
        if let ownership { Darwin.close(ownership) }
    }

    var state: State { guardLock.withLock { current } }

    /// Whether this copy holds the lock file that says "the vault is mine while I have it open".
    var holdsOwnership: Bool { guardLock.withLock { ownership != nil } }

    /// Versions before 0.11.9 take no lock file, so a mount this door did not make is also left alone while another copy runs.
    @Sendable static func anotherCopyOfThisAppIsRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { $0 != .current }
    }

    // MARK: Operations

    func create(password: String) async -> VaultError? {
        await inTurn { await self.createImage(password: password) }
    }

    func changePassword(from old: String, to new: String) async -> VaultError? {
        await inTurn { await self.changeImagePassword(from: old, to: new) }
    }

    func unlock(password: String) async -> UnlockOutcome {
        let requestsBefore = guardLock.withLock { lockRequests }
        return await inTurn { await self.mount(password: password, requestsBefore: requestsBefore) }
    }

    /// Stops an unlock that is still mounting and voids the ones waiting their turn. Never blocks.
    func interruptUnlock() {
        guardLock.withLock {
            lockRequests += 1
            attaching?.cancel()
        }
    }

    func lock() async -> LockOutcome {
        interruptUnlock()
        if let settled = guardLock.withLock({ settledWithoutATurn }) { return settled }
        return await inTurn { await self.closeVolume() }
    }

    func startLock() -> PendingLock {
        let pending = PendingLock()
        pending.task = Task.detached { [self] in
            let outcome = await lock()
            pending.settle(outcome)
            return outcome
        }
        return pending
    }

    /// A vault found mounted at launch is a crash leftover unless a running copy holds it.
    func recoverAtLaunch() async -> LockOutcome {
        await inTurn { await self.closeLeftover() }
    }

    func idle() async {
        await guardLock.withLock { lastOperation }?.value
    }

    /// Runs no program, so it answers at once: the volume is simply gone.
    func noticeOutsideEject() -> Bool {
        let noticed = guardLock.withLock {
            guard current == .open, !disk.isOpen else { return false }
            current = .closed
            releaseOwnership()
            return true
        }
        if noticed { disk.removeEmptyMountPoint() }
        return noticed
    }

    // MARK: One at a time

    private func inTurn<Outcome: Sendable>(_ operation: @escaping @Sendable () async -> Outcome) async -> Outcome {
        let turn: Task<Outcome, Never> = guardLock.withLock {
            let previous = lastOperation
            let turn = Task.detached {
                await previous?.value
                return await operation()
            }
            lastOperation = Task.detached { _ = await turn.value }
            return turn
        }
        return await turn.value
    }

    private var settledWithoutATurn: LockOutcome? {
        switch current {
        case .closed: .locked
        case .openElsewhere: .notOurs
        case .mounting, .open, .closing: nil
        }
    }

    // MARK: Mounting

    private func mount(password: String, requestsBefore: Int) async -> UnlockOutcome {
        guard guardLock.withLock({ lockRequests == requestsBefore }) else { return .lockedMeanwhile }
        if guardLock.withLock({ current == .open }) { return .opened }
        guard takeOwnership() else {
            guardLock.withLock { current = disk.isOpen ? .openElsewhere : .closed }
            return .refused(.openInAnotherCopy)
        }
        if let refusal = await clearTheWay() {
            guardLock.withLock {
                releaseOwnership()
                current = disk.isOpen ? .openElsewhere : .closed
            }
            return .refused(refusal)
        }
        let mountPoint = disk.location.mountPoint
        let image = disk.location.image
        let attach: Task<Shell.Result, Error>? = guardLock.withLock {
            guard lockRequests == requestsBefore else { return nil }
            current = .mounting
            let attach = Task.detached { [tool, bounds] in
                try await tool.run(VaultDisk.diskutil, ["image", "--stdinpass", "attach", "--nobrowse", "--mountPoint", mountPoint.path, image.path],
                                   Data(password.utf8), .seconds(bounds.attach))
            }
            attaching = attach
            return attach
        }
        guard let attach else { return abandonMount(.lockedMeanwhile) }
        let attached = await attach.result
        let lockedMeanwhile = guardLock.withLock {
            attaching = nil
            return lockRequests != requestsBefore
        }
        if lockedMeanwhile { return leaveToTheLock() }
        switch attached {
        case .success(let result) where result.succeeded && disk.isOpen:
            disk.markVolumeUnsearchable()
            guardLock.withLock { current = .open }
            return .opened
        case .success(let result):
            let refusal: VaultError = VaultDisk.isWrongPassword(result) ? .wrongPassword : .diskTool(action: "open", message: VaultDisk.reason(result))
            return await undoMount(refusal)
        case .failure(let error):
            return await undoMount(.diskTool(action: "open", message: error.localizedDescription))
        }
    }

    /// Before attaching: nothing mounted that is not ours to eject, and no files in the folder the volume will cover.
    private func clearTheWay() async -> VaultError? {
        if disk.isOpen {
            guard !anotherCopyIsRunning() else { return .openInAnotherCopy }
            if let failure = await ejectThenForce() { return .diskTool(action: "lock", message: failure) }
        }
        do {
            try disk.refuseFilesLeftOutside()
            if !FileManager.default.fileExists(atPath: disk.location.mountPoint.path) {
                try FileManager.default.createDirectory(at: disk.location.mountPoint, withIntermediateDirectories: false)
            }
            return nil
        } catch {
            return error as? VaultError ?? .diskTool(action: "open", message: error.localizedDescription)
        }
    }

    private func abandonMount(_ outcome: UnlockOutcome) -> UnlockOutcome {
        disk.removeEmptyMountPoint()
        guardLock.withLock {
            releaseOwnership()
            current = .closed
        }
        return outcome
    }

    /// A lock asked for this mount to stop. The lock is next in line and does the one eject, so nothing is ejected here.
    private func leaveToTheLock() -> UnlockOutcome {
        guard disk.isOpen else { return abandonMount(.lockedMeanwhile) }
        guardLock.withLock { current = .open }
        return .lockedMeanwhile
    }

    private func undoMount(_ refusal: VaultError) async -> UnlockOutcome {
        guard disk.isOpen, let failure = await ejectThenForce() else { return abandonMount(.refused(refusal)) }
        Log.error("Vault left mounted by a failed unlock", category: VaultLog.category, ["eject": failure])
        guardLock.withLock { current = .open }
        return .refused(refusal)
    }

    // MARK: Closing

    private func closeVolume() async -> LockOutcome {
        let settled: LockOutcome? = guardLock.withLock {
            if let settled = settledWithoutATurn { return settled }
            current = .closing
            return nil
        }
        if let settled { return settled }
        if let failure = await ejectThenForce() {
            guardLock.withLock { current = .open }
            return .stillMounted(reason: failure)
        }
        return closed()
    }

    private func closeLeftover() async -> LockOutcome {
        guard guardLock.withLock({ current == .openElsewhere }) else { return guardLock.withLock { settledWithoutATurn } ?? .locked }
        guard disk.isOpen else { return closed() }
        guard takeOwnership() else { return .notOurs }
        guard !anotherCopyIsRunning() else {
            guardLock.withLock { releaseOwnership() }
            return .notOurs
        }
        if let failure = await ejectThenForce() {
            guardLock.withLock { releaseOwnership() }
            return .stillMounted(reason: failure)
        }
        return closed()
    }

    private func closed() -> LockOutcome {
        disk.removeEmptyMountPoint()
        guardLock.withLock {
            releaseOwnership()
            current = .closed
        }
        return .locked
    }

    /// The only place an eject or a detach is run, and only ever from the operation whose turn it is.
    private func ejectThenForce() async -> String? {
        guard disk.isOpen else { return nil }
        let path = disk.location.mountPoint.path
        let eject = await lockStep(VaultDisk.diskutil, ["eject", path])
        guard disk.isOpen else { return nil }
        let forced = await lockStep(VaultDisk.hdiutil, ["detach", "-force", path])
        guard disk.isOpen else { return nil }
        Log.error("Vault eject failed", category: VaultLog.category, ["eject": VaultDisk.reason(eject), "forced_detach": VaultDisk.reason(forced)])
        return VaultDisk.reason(forced)
    }

    private func lockStep(_ path: String, _ arguments: [String]) async -> Shell.Result {
        do {
            return try await tool.run(path, arguments, nil, .seconds(bounds.lockStep))
        } catch {
            return Shell.Result(status: VaultTool.didNotFinish, out: "", err: error.localizedDescription)
        }
    }

    // MARK: Writes that are never cut short

    private func createImage(password: String) async -> VaultError? {
        guard !disk.exists else { return .alreadyExists }
        let unfinished = disk.location.folder.appendingPathComponent("\(VaultDisk.unfinishedPrefix)\(UUID().uuidString)\(VaultDisk.unfinishedSuffix)")
        do {
            try disk.prepareFolder()
            let result = try await tool.run(VaultDisk.diskutil, ["image", "--stdinpass", "create", "blank", "--encrypt",
                                                            "--size", Self.maximumSize, "--volumeName", Self.volumeName,
                                                            "--fs", "APFS", unfinished.path],
                                            Data(password.utf8), .untilFinished)
            guard result.succeeded else { throw VaultError.diskTool(action: "be created", message: VaultDisk.reason(result)) }
            try disk.moveIntoPlace(unfinished)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: unfinished)
            return error as? VaultError ?? .diskTool(action: "be created", message: error.localizedDescription)
        }
    }

    private func changeImagePassword(from old: String, to new: String) async -> VaultError? {
        let borrowed = guardLock.withLock { ownership == nil }
        if borrowed, !takeOwnership() { return .openInAnotherCopy }
        defer { if borrowed { guardLock.withLock { releaseOwnership() } } }
        do {
            let result = try await tool.run(VaultDisk.diskutil, ["image", "--stdinpass", "chpass", disk.location.image.path],
                                            Data("\(old)\n\(new)\n".utf8), .untilFinished)
            if result.succeeded { return nil }
            return VaultDisk.isWrongPassword(result) ? .wrongPassword : .diskTool(action: "change its password", message: VaultDisk.reason(result))
        } catch {
            return .diskTool(action: "change its password", message: error.localizedDescription)
        }
    }

    // MARK: Ownership across copies

    /// `flock` belongs to the open file, so a copy that dies gives it up without anyone having to notice.
    private func takeOwnership() -> Bool {
        if guardLock.withLock({ ownership != nil }) { return true }
        try? FileManager.default.createDirectory(at: disk.location.folder, withIntermediateDirectories: true)
        let path = disk.location.folder.appendingPathComponent(Self.lockFileName).path
        // O_CLOEXEC: a diskutil left running after the app quits must not keep the vault claimed.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return false
        }
        let holder = Data("\(getpid()) \(Self.processStartTime)\n".utf8)
        ftruncate(descriptor, 0)
        _ = holder.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, 0) }
        guardLock.withLock { ownership = descriptor }
        return true
    }

    private func releaseOwnership() {
        guard let descriptor = ownership else { return }
        ownership = nil
        Darwin.close(descriptor)
    }

    private static let processStartTime: Int = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_proc.p_starttime.tv_sec
    }()
}
