import Foundation

/// Finds duplicates, in the whole vault or for files being added to it. It remembers each file's digest and look while
/// the vault is open, so a second pass, or the Duplicates view after an add, reads only what is new.
@MainActor
final class VaultMatchCache {
    private var digests: [VaultItem: Data] = [:]
    private var looks: [VaultItem: VaultLook] = [:]
    private var forgets = 0
    private let digest: @Sendable (VaultItem) throws -> Data

    init(digest: @escaping @Sendable (VaultItem) throws -> Data = { try VaultMover.sha256($0.url) }) {
        self.digest = digest
    }

    /// Every set of duplicates in the vault. Nil when the task was cancelled or the vault locked meanwhile.
    func groups(in snapshot: [VaultItem], lengths: [VaultItem: Double],
                remembered: VaultDistinctPairs? = nil) async -> [VaultDuplicates.Group]? {
        let candidates = VaultDuplicates.lookCandidates(in: snapshot, durations: lengths)
        return await find(in: snapshot, touching: nil, lookCandidates: candidates, lengths: lengths, remembered: remembered)
    }

    /// The sets that include one of `incoming`: each with every vault file and every other incoming file it matches.
    func matches(for incoming: [VaultItem], in vault: [VaultItem], lengths: [VaultItem: Double],
                 remembered: VaultDistinctPairs? = nil) async -> [VaultDuplicates.Group]? {
        let everything = vault + incoming
        let anchors = Set(incoming)
        let candidates = VaultDuplicates.lookCandidates(in: everything, durations: lengths, near: anchors)
        return await find(in: everything, touching: anchors, lookCandidates: candidates, lengths: lengths, remembered: remembered)
    }

    func digests(of items: [VaultItem]) async throws -> [Data] {
        var found: [Data] = []
        for item in items {
            if let known = digests[item] {
                found.append(known)
                continue
            }
            let read = digest
            let value = try await Task.detached(priority: .userInitiated) { try read(item) }.value
            digests[item] = value
            found.append(value)
        }
        return found
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

    /// `lookCandidates` nil: looks are not compared at all.
    private func find(in items: [VaultItem], touching: Set<VaultItem>?, lookCandidates: [VaultItem]?,
                      lengths: [VaultItem: Double], remembered: VaultDistinctPairs?) async -> [VaultDuplicates.Group]? {
        let forgetsBefore = forgets
        let present = Set(items)
        let unlooked = (lookCandidates ?? []).filter { looks[$0] == nil }
        let newLooks = await VaultLookReader.looks(of: unlooked, durations: lengths)
        guard !Task.isCancelled, forgets == forgetsBefore else { return nil }
        looks.merge(newLooks) { _, new in new }
        let knownLooks = lookCandidates == nil ? [:] : looks.filter { present.contains($0.key) }
        let known = digests.filter { present.contains($0.key) }
        let kept = remembered?.remembered ?? VaultDistinctPairs.Remembered()
        let stop = StopFlag()
        let (groups, found) = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { [read = digest] in
                var found = known
                func digestOf(_ item: VaultItem) throws -> Data {
                    if let digest = found[item] { return digest }
                    guard !stop.isSet else { throw CancellationError() }
                    let digest = try read(item)
                    found[item] = digest
                    return digest
                }
                let paired = VaultDuplicates.pairs(in: items, digest: digestOf, durations: lengths, looks: knownLooks,
                                                   touching: touching)
                let copiesOf = Dictionary(grouping: found.values, by: { $0 }).mapValues(\.count)
                let wanted = paired.pairs.filter { pair in
                    guard !kept.isEmpty, let a = try? digestOf(pair.first), let b = try? digestOf(pair.second) else { return true }
                    return !kept.hides(a, b, count: copiesOf[a] ?? 2)
                }
                return (VaultDuplicates.groups(joining: wanted, digests: found), found)
            }.value
        } onCancel: { stop.set() }
        guard forgets == forgetsBefore else { return nil }
        digests.merge(found) { _, new in new }
        return Task.isCancelled ? nil : groups
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
