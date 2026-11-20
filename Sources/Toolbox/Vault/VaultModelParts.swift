import AppKit

extension VaultModel {
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

    func volumeDidUnmount(_ volume: URL?) {
        guard volume?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { return }
        lockIfClosedFromOutside()
    }

    func addDebugFiles() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--vault-debug-add"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        add([folder])
        #endif
    }

    func watchSystem() -> [NSObjectProtocol] {
        var observers: [NSObjectProtocol] = []
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockBeforeSleep() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockBecauseTheScreenLocked() }
        })
        quitGuard.prepare(in: .shared)
        observers.append(workspace.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeDidUnmount(volume) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.lockIfClosedFromOutside() }
        })
        return observers
    }

    func changePassword(current: String, new: String, confirmation: String) async -> Bool {
        do {
            try VaultDisk.validateNewPassword(new, confirmation: confirmation)
            let refusal = await door.changePassword(from: current, to: new)
            quitGuard.forgetRefusal()
            if let refusal { throw refusal }
            Log.info("Vault password changed", category: VaultLog.category)
            if passwordKeeper.hasPassword { rememberForTouchID(new) }
            return true
        } catch {
            message = error.localizedDescription
            if !VaultNotices.isUserMistake(error) { VaultLog.failure("Vault password change failed", error) }
            return false
        }
    }

    func rememberForTouchID(_ password: String) {
        guard usesTouchID else { return passwordKeeper.forget() }
        do {
            try passwordKeeper.save(password)
        } catch {
            usesTouchID = false
            passwordKeeper.forget()
            VaultLog.failure("Saving the vault password for Touch ID failed", error)
        }
    }
}
