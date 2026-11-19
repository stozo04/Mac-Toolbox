import Foundation

/// The move into the vault that is running: its task, how far it is, and which of its files are not confirmed yet, so a
/// vault closed from outside can say what happened to each one.
struct VaultMoveTracker {
    struct OutsideClose {
        let failures: [VaultMoveFailure]
        let stillToMove: Int
        let unconfirmed: Int
        let notice: String
    }

    struct Correction {
        let listed: Int
        let failure: VaultMoveFailure
        let noticeBefore: String
        let notice: String
    }

    var task: Task<Void, Never>?
    private(set) var progress: VaultModel.MoveProgress?
    private(set) var stillToMove: [URL] = []
    private var current: UUID?
    private var outsideClose: (duringImport: Bool, unconfirmed: Int)?

    var isRunning: Bool { task != nil }

    mutating func begin(_ files: [URL]) -> UUID {
        let id = UUID()
        current = id
        stillToMove = files
        progress = VaultModel.MoveProgress(done: 0, total: files.count)
        return id
    }

    /// False once the vault locked or another move began: what that move still reports is no longer this one's to show.
    func isCurrent(_ id: UUID) -> Bool {
        current == id
    }

    mutating func settled(_ file: URL) {
        stillToMove.removeAll { $0 == file }
        progress?.done += 1
    }

    /// Ends the move. What was said about the last outside close stays, for a file that finishes after it.
    mutating func end() {
        task = nil
        current = nil
        stillToMove = []
        progress = nil
    }

    /// A file that is gone from where it was had already been copied in and checked when the vault closed.
    mutating func closedFromOutside() -> OutsideClose {
        let duringImport = isRunning || !stillToMove.isEmpty
        let unconfirmed = stillToMove.filter { !FileManager.default.fileExists(atPath: $0.path) }
        let failures = stillToMove.map {
            VaultMoveFailure(name: $0.lastPathComponent,
                             reason: unconfirmed.contains($0) ? VaultNotices.finishedAsVaultClosed : VaultMoveError.vaultNotOpen.localizedDescription,
                             source: $0)
        }
        outsideClose = (duringImport, unconfirmed.count)
        return OutsideClose(failures: failures, stillToMove: stillToMove.count, unconfirmed: unconfirmed.count,
                            notice: VaultNotices.closedFromOutside(duringImport: duringImport, unconfirmed: unconfirmed.count))
    }

    /// The move in flight when the eject was noticed can still finish: its copy was already checked and saved to the disk.
    /// Nil unless `file` is listed in `failures` as kept and has in fact been moved.
    mutating func correction(for file: URL, among failures: [VaultMoveFailure]) -> Correction? {
        let kept = VaultMoveError.vaultNotOpen.localizedDescription
        guard !FileManager.default.fileExists(atPath: file.path), let said = outsideClose,
              let listed = failures.firstIndex(where: { $0.source == file && $0.reason == kept }) else { return nil }
        outsideClose = (said.duringImport, said.unconfirmed + 1)
        return Correction(
            listed: listed,
            failure: VaultMoveFailure(name: file.lastPathComponent, reason: VaultNotices.finishedAsVaultClosed, source: file),
            noticeBefore: VaultNotices.closedFromOutside(duringImport: said.duringImport, unconfirmed: said.unconfirmed),
            notice: VaultNotices.closedFromOutside(duringImport: said.duringImport, unconfirmed: said.unconfirmed + 1))
    }
}
