import Foundation

/// Finds duplicates, in the whole vault or for files being added to it. It remembers each file's digest and look while
/// the vault is open, so a second pass, or the Duplicates view after an add, reads only what is new. A file changed since
/// (same size, new modification date) is read again: a stale digest could call two different files exact copies.
@MainActor
final class VaultMatchCache {
    private var digests: [VaultItem: Data] = [:]
    private var looks: [VaultItem: VaultLook] = [:]
    private var stamps: [VaultItem: Date] = [:]
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

    /// The sets that include one of `incoming`: each with every file the Duplicates view would put in the same set, so
    /// also a vault copy that matches only through another vault copy. Each pass reads around the files found so far,
    /// until no new file joins.
    func matches(for incoming: [VaultItem], in vault: [VaultItem], lengths: [VaultItem: Double],
                 remembered: VaultDistinctPairs? = nil) async -> [VaultDuplicates.Group]? {
        let everything = vault + incoming
        var reached = Set(incoming)
        while true {
            let candidates = VaultDuplicates.lookCandidates(in: everything, durations: lengths, near: reached)
            guard let groups = await find(in: everything, touching: reached, lookCandidates: candidates, lengths: lengths,
                                          remembered: remembered) else { return nil }
            let grown = reached.union(groups.flatMap(\.copies))
            if grown == reached { return groups.filter { $0.copies.contains(where: incoming.contains) } }
            reached = grown
        }
    }

    func digests(of items: [VaultItem]) async throws -> [Data] {
        forgetChanged(items)
        var found: [Data] = []
        for item in items {
            if let known = digests[item] {
                found.append(known)
                continue
            }
            let read = digest
            let value = try await Task.detached(priority: .userInitiated) { try read(item) }.value
            digests[item] = value
            stamp(item)
            found.append(value)
        }
        return found
    }

    func carry(from old: VaultItem, to new: VaultItem) {
        if let digest = digests.removeValue(forKey: old) { digests[new] = digest }
        if let look = looks.removeValue(forKey: old) { looks[new] = look }
        if let date = stamps.removeValue(forKey: old) { stamps[new] = date }
    }

    func forget() {
        forgets += 1
        digests = [:]
        looks = [:]
        stamps = [:]
    }

    /// `lookCandidates` nil: looks are not compared at all.
    private func find(in items: [VaultItem], touching: Set<VaultItem>?, lookCandidates: [VaultItem]?,
                      lengths: [VaultItem: Double], remembered: VaultDistinctPairs?) async -> [VaultDuplicates.Group]? {
        forgetChanged(items)
        let forgetsBefore = forgets
        let present = Set(items)
        let unlooked = (lookCandidates ?? []).filter { looks[$0] == nil }
        let newLooks = await VaultLookReader.looks(of: unlooked, durations: lengths)
        guard !Task.isCancelled, forgets == forgetsBefore else { return nil }
        looks.merge(newLooks) { _, new in new }
        newLooks.keys.forEach(stamp)
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
        for (item, digest) in found where digests[item] != digest {
            digests[item] = digest
            stamp(item)
        }
        return Task.isCancelled ? nil : groups
    }
}

extension VaultMatchCache {
    private func forgetChanged(_ items: [VaultItem]) {
        for item in items where stamps[item] != nil && stamps[item] != Self.modified(item) {
            digests[item] = nil
            looks[item] = nil
            stamps[item] = nil
        }
    }

    private func stamp(_ item: VaultItem) {
        stamps[item] = Self.modified(item)
    }

    private static func modified(_ item: VaultItem) -> Date? {
        // A URL caches the values it read, so a fresh one is asked: the same instance would report the old date.
        (try? URL(fileURLWithPath: item.url.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}
