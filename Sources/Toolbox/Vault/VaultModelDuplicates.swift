import Foundation

/// A download Download Video put in without asking, beside the copies it may duplicate; `digest` is how its queue
/// entry knows it, so the entry can be closed even after the download went to the Trash.
struct VaultDownloadMatch: Equatable {
    let group: VaultComparison.Group
    let digest: Data
}

/// The Duplicates view and the downloads waiting for a look: both choose on the comparison screen among copies already
/// in the vault, so an unticked one goes to the vault's Trash.
extension VaultModel {
    /// Walks `groups` on the comparison screen, one set at a time.
    func review(_ groups: [VaultDuplicates.Group]) {
        guard phase == .open, !moves.isRunning, comparison == nil, !groups.isEmpty else { return }
        let shown = groups.map { group in
            VaultComparison.Group(copies: group.copies.map { VaultComparison.Copy(item: $0, place: .vault) }, match: group.match)
        }
        walk(shown, origin: .vault)
    }

    /// Checks the downloads Download Video put in without asking, in the background, so the library can offer to
    /// compare the ones that have a copy already. Downloads with none are done with.
    func checkDownloads() {
        guard phase == .open || phase == .opening, let store = duplicatesStore else { return }
        let generation = lockCount
        Task {
            let pending = (try? store.pendingReviews()) ?? []
            guard !pending.isEmpty else { return }
            let lengths = await lengths(of: items)
            var found: [VaultDownloadMatch] = []
            var clear: [Data] = []
            for entry in pending {
                guard lockCount == generation else { return }
                guard let downloaded = items.first(where: { VaultLibrary.relativePath(of: $0.url, in: root) == entry.path }),
                      let groups = await matchCache.matches(for: [downloaded], in: items.filter { $0 != downloaded },
                                                            lengths: lengths, remembered: duplicatesStore), !groups.isEmpty else {
                    clear.append(entry.digest)
                    continue
                }
                found += groups.map { group in
                    let copies = group.copies.map { VaultComparison.Copy(item: $0, place: $0 == downloaded ? .downloaded : .vault) }
                    return VaultDownloadMatch(group: VaultComparison.Group(copies: copies, match: group.match), digest: entry.digest)
                }
            }
            guard lockCount == generation else { return }
            finishReviews(clear)
            downloadMatches = found
        }
    }

    func reviewDownloads() {
        guard phase == .open, !moves.isRunning, comparison == nil, !downloadMatches.isEmpty else { return }
        let matches = downloadMatches
        downloadMatches = []
        walk(matches.map(\.group), origin: .downloads) { [weak self] finished in
            guard let self else { return }
            finishReviews(matches.prefix(finished).map(\.digest))
            downloadMatches = Array(matches.dropFirst(finished))
        }
    }

    private func finishReviews(_ digests: [Data]) {
        guard !digests.isEmpty else { return }
        do {
            try duplicatesStore?.finishReviews(digests)
        } catch {
            VaultLog.failure("Vault duplicates memory failed", error)
        }
    }

    private func walk(_ groups: [VaultComparison.Group], origin: VaultComparison.Origin,
                      whenDone: @escaping @MainActor (_ finished: Int) async -> Void = { _ in }) {
        let comparison = VaultComparison(origin: origin) { [weak self] in await self?.playableURL(for: $0) ?? $0.url }
        self.comparison = comparison
        let generation = lockCount
        Task {
            defer {
                comparison.end()
                if self.comparison === comparison { self.comparison = nil }
            }
            var trashed = 0
            var finished = 0
            for (number, group) in groups.enumerated() {
                let present = group.copies.filter { FileManager.default.fileExists(atPath: $0.item.url.path) }
                if present.count > 1 {
                    let current = VaultComparison.Group(copies: present, match: group.match)
                    guard case .keep(let kept) = await comparison.choose(current, number: number + 1, of: groups.count),
                          lockCount == generation, phase == .open else { break }
                    trashed += await carryOut(kept, on: current)
                }
                finished += 1
            }
            if lockCount == generation { await whenDone(finished) }
            if trashed > 0 { notice = trashed == 1 ? "1 copy moved to the vault's Trash." : "\(trashed) copies moved to the vault's Trash." }
            if mode == .duplicates { findDuplicates() }
        }
    }

    /// Returns how many copies went to the Trash.
    private func carryOut(_ kept: Set<VaultItem.ID>, on group: VaultComparison.Group) async -> Int {
        let copies = group.copies.map(\.item)
        guard VaultDuplicates.isStillIntact(copies) else {
            message = "These copies changed since they were compared. Look again before choosing."
            return 0
        }
        if kept.count == copies.count {
            await rememberKeptTogether(copies)
            return 0
        }
        guard copies.contains(where: { kept.contains($0.id) }) else { return 0 }
        return await moveToTrash(copies.filter { !kept.contains($0.id) }).count
    }
}
