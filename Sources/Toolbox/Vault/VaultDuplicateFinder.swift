import Foundation

/// Finds the sets of duplicates in the vault. It remembers each file's digest and look while the vault is open, so a
/// second pass reads only what is new.
@MainActor
final class VaultDuplicateFinder {
    private var digests: [VaultItem: Data] = [:]
    private var looks: [VaultItem: VaultLook] = [:]
    private var forgets = 0
    private let digest: @Sendable (VaultItem) throws -> Data

    init(digest: @escaping @Sendable (VaultItem) throws -> Data = { try VaultMover.sha256($0.url) }) {
        self.digest = digest
    }

    /// Nil when the task was cancelled or the vault locked meanwhile.
    func groups(in snapshot: [VaultItem], lengths: [VaultItem: Double]) async -> [VaultDuplicates.Group]? {
        let forgetsBefore = forgets
        let present = Set(snapshot)
        let unlooked = VaultDuplicates.lookCandidates(in: snapshot, durations: lengths).filter { looks[$0] == nil }
        let newLooks = await VaultLookReader.looks(of: unlooked, durations: lengths)
        guard !Task.isCancelled, forgets == forgetsBefore else { return nil }
        looks.merge(newLooks) { _, new in new }
        let knownLooks = looks.filter { present.contains($0.key) }
        let known = digests.filter { present.contains($0.key) }
        let stop = StopFlag()
        let (groups, found) = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { [read = digest] in
                var found = known
                let groups = VaultDuplicates.groups(in: snapshot, digest: { item in
                    if let digest = found[item] { return digest }
                    guard !stop.isSet else { throw CancellationError() }
                    let digest = try read(item)
                    found[item] = digest
                    return digest
                }, durations: lengths, looks: knownLooks)
                return (groups, found)
            }.value
        } onCancel: { stop.set() }
        guard forgets == forgetsBefore else { return nil }
        digests.merge(found) { _, new in new }
        return Task.isCancelled ? nil : groups
    }

    func carry(from old: VaultItem, to new: VaultItem) {
        if let digest = digests.removeValue(forKey: old) { digests[new] = digest }
        if let look = looks.removeValue(forKey: old) { looks[new] = look }
    }

    func forget() {
        forgets += 1
        digests = [:]
        looks = [:]
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
