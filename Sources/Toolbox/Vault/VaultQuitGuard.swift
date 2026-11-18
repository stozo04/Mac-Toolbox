import AppKit

/// What the vault does when the app is asked to quit: lock first, and refuse once if the vault is still mounted.
@MainActor
final class VaultQuitGuard {
    static let slack: TimeInterval = 2

    private unowned let vault: VaultModel
    private var refusal: String?
    private var quitsAnywayIfStillOpen = false
    var showVaultPage: (() -> Void)?

    init(_ vault: VaultModel) { self.vault = vault }

    /// The door's own lock bound and a little more, so a lock that ends at its bound is still heard.
    var patience: Duration { .seconds(vault.door.bounds.lock + Self.slack) }

    func prepare(in preparation: QuitPreparation) {
        preparation.add(patience: patience, mayQuitUnfinished: { [weak self] in self?.mayQuit() ?? true },
                        { [weak self] in self?.lockBeforeQuitting() })
    }

    func showRefusal(on state: AppState) {
        showVaultPage = { [weak state] in state?.page = .vault }
    }

    func lockBeforeQuitting() -> Task<Bool, Never>? {
        guard vault.isWorking || vault.isLocking || isMountedByThisCopy || vault.door.unfinishedWrite != nil else { return nil }
        quitsAnywayIfStillOpen = refusal != nil && vault.message == refusal
        let locking = vault.lockImmediately()
        return Task { [vault] in
            await locking.value
            await vault.door.idle()
            return mayQuit()
        }
    }

    /// Answered from the door's state alone, so it is also right when the lock has not finished within the patience.
    func mayQuit() -> Bool {
        let write = vault.door.unfinishedWrite
        guard isMountedByThisCopy || write != nil else {
            forgetRefusal()
            return true
        }
        let details = ["door": "\(vault.door.state)", "reason": VaultNotices.whyNotLocked(during: write, failure: vault.lastLockFailure)]
        guard !quitsAnywayIfStillOpen else {
            Log.error("Quit before the vault was locked", category: VaultLog.category, details)
            return true
        }
        Log.error("Quit refused because the vault is not locked yet", category: VaultLog.category, details)
        let refused = write.map(VaultNotices.quitRefused(during:)) ?? VaultNotices.quitRefused(reason: vault.lastLockFailure)
        refusal = refused
        vault.message = refused
        showVaultPage?()
        return false
    }

    /// A refusal stops being true once the vault is locked or the write it waited for is done.
    func forgetRefusal() {
        if let refusal, vault.message == refusal { vault.message = nil }
        refusal = nil
    }

    private var isMountedByThisCopy: Bool {
        let state = vault.door.state
        return state == .mounting || state == .open || state == .closing
    }
}
