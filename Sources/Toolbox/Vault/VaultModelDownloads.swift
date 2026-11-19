import Foundation

/// What Download Video's "Add to Vault" asks of the vault.
extension VaultModel {
    /// Opens the vault with a password the user did not type here, so a refusal leaves no message or count on the door.
    func openQuietly(password: String) async -> VaultDoor.UnlockOutcome? {
        guard phase == .locked, !isWorking, !isLocking else { return nil }
        isWorking = true
        defer { isWorking = false }
        let locksBefore = lockCount
        let outcome = await door.unlock(password: password)
        if case .opened = outcome, lockCount == locksBefore {
            openedForDownloads = true
            beginOpening()
            finishOpening()
        } else if case .refused = outcome, door.state == .open {
            message = VaultNotices.leftMountedByFailedUnlock
        }
        return outcome
    }

    /// Moves one file in, as a drop does, and returns where it landed in the vault.
    func moveIn(_ file: URL) async throws -> URL {
        guard phase == .open, !isLocking, !lockIfClosedFromOutside() else { throw VaultMoveError.vaultNotOpen }
        guard !moves.isRunning else { throw VaultMoveError.busy }
        let id = moves.begin([file])
        let move = Task { [moveFile, root] in try await moveFile(file, root) }
        moves.task = Task { await withTaskCancellationHandler { _ = await move.result } onCancel: { move.cancel() } }
        let result = await move.result
        let ownMove = moves.isCurrent(id)
        if ownMove { moves.end() } else { correctReportIfMovedAfterAll(file) }
        if case .failure(VaultMoveError.originalKept(_, let copy)) = result, ownMove { showMovedIn(copy) }
        let moved = try result.get()
        if ownMove { showMovedIn(moved) }
        return moved
    }

    /// Puts the file first in line for the search index and waits for it, at most `limit` (`searchWaitLimit` when not given).
    /// False when there is no search model, the file could not be read, the vault locked first, or the wait ran out.
    func makeSearchable(_ file: URL, waitingAtMost limit: Duration? = nil) async -> Bool {
        guard phase == .open, !isLocking,
              let item = items.first(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) else { return false }
        startSearch()
        guard isSearchRunning else { return false }
        putFirstInIndex(item)
        let limit = limit ?? searchWaitLimit
        return await searchWaiters.wait(for: item.id, atMost: limit) { refreshIndex() }
    }
}
