import Foundation

enum DownloadVaultOpening: Equatable {
    case opened
    case cancelled
    case unavailable(String)
}

/// The part of the vault Download Video uses, so its tests can stand in for the encrypted disk and Touch ID.
@MainActor
protocol DownloadVault: AnyObject {
    var acceptsFiles: Bool { get }
    func openWithTouchID() async -> DownloadVaultOpening
    func moveIn(_ file: URL) async throws -> URL
    func makeSearchable(_ file: URL) async -> Bool
    func lockAndConfirm() async -> Bool
}

extension VaultModel: DownloadVault {
    static let lockAttempts = 3
    static let touchIDReason = "add the downloaded videos to your Vault"

    var acceptsFiles: Bool { phase == .open && !isLocking }

    func openWithTouchID() async -> DownloadVaultOpening {
        if acceptsFiles { return .opened }
        guard usesTouchID, passwordKeeper.hasPassword else { return .unavailable(VaultTouchIDKey.notSetUp) }
        switch await passwordKeeper.password(reason: Self.touchIDReason) {
        case .cancelled:
            return .cancelled
        case .failed(let reason):
            return .unavailable(reason)
        case .password(let password):
            if acceptsFiles { return .opened }
            let outcome = await openQuietly(password: password)
            if case .refused? = outcome, door.state == .open { _ = await lockAndConfirm() }
            switch outcome {
            case .opened? where acceptsFiles:
                return .opened
            case .refused(.wrongPassword)?:
                passwordKeeper.forget()
                usesTouchID = false
                Log.warning("Saved vault password no longer opens the vault", category: VaultLog.category)
                return .unavailable("The Vault's password changed. Unlock it once on the Vault page to set up Touch ID again.")
            case .refused(let refusal)?:
                VaultLog.failure("Vault did not open for downloads", refusal)
                return .unavailable("The Vault didn't open: \(refusal.localizedDescription)")
            case .opened?, .lockedMeanwhile?, nil:
                return .unavailable("The Vault is busy. Try again in a moment.")
            }
        }
    }

    /// Locks, then believes it only when the door's answer to the lock, its state and a second ask of the door all say locked.
    /// A vault another copy of Toolbox has open is not this copy's to lock.
    func lockAndConfirm() async -> Bool {
        for attempt in 1...Self.lockAttempts {
            await lockImmediately().value
            if door.state == .openElsewhere { return true }
            let lockSucceeded = lastLockFailure == nil
            let doorIsClosed = door.state == .closed
            let doorConfirms = await door.lock() == .locked
            if lockSucceeded && doorIsClosed && doorConfirms && phase != .open { return true }
            Log.warning("Vault not locked after adding downloads", category: VaultLog.category,
                        ["attempt": String(attempt), "lock": String(lockSucceeded), "state": String(doorIsClosed),
                         "confirmed": String(doorConfirms)])
        }
        Log.error("Vault still open after adding downloads", category: VaultLog.category,
                  ["reason": lastLockFailure ?? "unknown"])
        return false
    }
}

struct VaultSendReport: Equatable {
    var moved = 0
    var failed = 0
    var notSearchable = 0
    var lockedBeforeSending = 0
    var notAddedBecause: String?
    var stillOpen = false
}
