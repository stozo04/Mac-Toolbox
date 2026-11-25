import Foundation

enum DownloadVaultOpening: Equatable {
    case opened
    /// Opened by hand on the Vault page, so the send leaves it open.
    case alreadyOpen
    case cancelled
    case unavailable(String, stillOpen: Bool = false)
}

enum VaultLockCheck: Equatable {
    case locked
    /// Another copy of Toolbox opened it, so this copy has nothing to lock and cannot say it is locked.
    case heldByAnotherCopy
    case stillOpen
}

/// The part of the vault Download Video uses, so its tests can stand in for the encrypted disk and Touch ID.
@MainActor
protocol DownloadVault: AnyObject {
    var acceptsFiles: Bool { get }
    func openWithTouchID() async -> DownloadVaultOpening
    func moveIn(_ file: URL) async throws -> URL
    func holdsExactCopy(of file: URL) async -> Bool
    func queueDuplicateCheck(of inVault: URL) async
    func makeSearchable(_ files: [URL], onAnswer: (Int) -> Void) async -> Int
    func lockAndConfirm() async -> VaultLockCheck
}

extension VaultModel: DownloadVault {
    static let lockAttempts = 3
    static let touchIDReason = "add the downloaded videos to your Vault"

    var acceptsFiles: Bool { phase == .open && !isLocking }

    func openWithTouchID() async -> DownloadVaultOpening {
        if acceptsFiles { return openedForDownloads ? .opened : .alreadyOpen }
        guard usesTouchID, passwordKeeper.hasPassword else { return .unavailable(VaultTouchIDKey.notSetUp) }
        switch await passwordKeeper.password(reason: Self.touchIDReason) {
        case .cancelled:
            return .cancelled
        case .failed(let reason):
            return .unavailable(reason)
        case .password(let password):
            if acceptsFiles { return openedForDownloads ? .opened : .alreadyOpen }
            let outcome = await openQuietly(password: password)
            var stillOpen = false
            if case .refused? = outcome, door.state == .open { stillOpen = await lockAndConfirm() == .stillOpen }
            switch outcome {
            case .opened? where acceptsFiles:
                return .opened
            case .refused(.wrongPassword)?:
                passwordKeeper.forget()
                usesTouchID = false
                Log.warning("Saved vault password no longer opens the vault", category: VaultLog.category)
                return .unavailable("The Vault's password changed. Unlock it once on the Vault page to set up Touch ID again.",
                                    stillOpen: stillOpen)
            case .refused(let refusal)?:
                VaultLog.failure("Vault did not open for downloads", refusal)
                return .unavailable("The Vault didn't open: \(refusal.localizedDescription)", stillOpen: stillOpen)
            case .opened?, .lockedMeanwhile?, nil:
                return .unavailable("The Vault is busy. Try again in a moment.")
            }
        }
    }

    /// Every file is put in line before any is waited for, so one pass of the index takes them all and the search model is
    /// loaded once. They share one deadline, a `searchWaitLimit` for each file: the order the waits start in is not fixed,
    /// so a limit per place in the list could cut off whichever file ended up last in line. Returns how many became
    /// searchable; `onAnswer` hears how many have been answered so far.
    func makeSearchable(_ files: [URL], onAnswer: (Int) -> Void) async -> Int {
        let sharedLimit = searchWaitLimit * files.count
        return await withTaskGroup(of: Bool.self) { waits in
            for file in files {
                waits.addTask { @MainActor in await self.makeSearchable(file, waitingAtMost: sharedLimit) }
            }
            var answered = 0
            var searchable = 0
            for await answer in waits {
                answered += 1
                if answer { searchable += 1 }
                onAnswer(answered)
            }
            return searchable
        }
    }

    /// Locks, then believes it only when the door's answer to the lock, its state and its released claim on the vault all say
    /// locked. Every check only reads the door: asking it to lock again would eject behind the model's back.
    /// A vault another copy of Toolbox has open is not this copy's to lock.
    func lockAndConfirm() async -> VaultLockCheck {
        for attempt in 1...Self.lockAttempts {
            await lockImmediately().value
            if door.state == .openElsewhere { return .heldByAnotherCopy }
            let lockSucceeded = lastLockFailure == nil
            let doorIsClosed = door.state == .closed
            let claimReleased = !door.holdsOwnership
            if lockSucceeded && doorIsClosed && claimReleased && phase != .open { return .locked }
            Log.warning("Vault not locked after adding downloads", category: VaultLog.category,
                        ["attempt": String(attempt), "lock": String(lockSucceeded), "state": String(doorIsClosed),
                         "claim_released": String(claimReleased)])
        }
        Log.error("Vault still open after adding downloads", category: VaultLog.category,
                  ["reason": lastLockFailure ?? "unknown"])
        return .stillOpen
    }
}

struct VaultSendReport: Equatable {
    var moved = 0
    var failed = 0
    var notSearchable = 0
    var lockedBeforeSending = 0
    var notAddedBecause: String?
    var stillOpen = false
    var lockedAgain = false
    var heldByAnotherCopy = false
    var keptOut = 0
    /// Not added because the Vault already holds the same file; sent from Downloads.
    var alreadyInVault = 0
    var skippedInVault = 0
    var usedVault = false
}
