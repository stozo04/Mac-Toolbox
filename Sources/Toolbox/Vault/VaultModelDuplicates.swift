import Foundation

/// Downloads Download Video put in without asking, beside the copies they may duplicate. Every queued download in the
/// set is marked as one, so none is taken for a vault copy; `digests` are how their queue entries know them, so the
/// entries can be closed even after a download went to the Trash.
struct VaultDownloadMatch: Equatable {
    let group: VaultComparison.Group
    let digests: [Data]
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
            var queued: [VaultItem.ID: Data] = [:]
            var downloads: [(entry: VaultDistinctPairs.PendingReview, item: VaultItem)] = []
            for entry in pending {
                if let item = items.first(where: { VaultLibrary.relativePath(of: $0.url, in: root) == entry.path }) {
                    queued[item.id] = entry.digest
                    downloads.append((entry, item))
                } else {
                    clear.append(entry.digest)
                }
            }
            var shown = Set<VaultItem.ID>()
            for (entry, downloaded) in downloads where !shown.contains(downloaded.id) {
                guard lockCount == generation else { return }
                guard let groups = await matchCache.matches(for: [downloaded], in: items.filter { $0 != downloaded },
                                                            lengths: lengths, remembered: duplicatesStore), !groups.isEmpty else {
                    clear.append(entry.digest)
                    continue
                }
                for group in groups {
                    let copies = group.copies.map { VaultComparison.Copy(item: $0, place: queued[$0.id] == nil ? .vault : .downloaded) }
                    let downloadsHere = group.copies.filter { queued[$0.id] != nil }
                    shown.formUnion(downloadsHere.map(\.id))
                    found.append(VaultDownloadMatch(group: VaultComparison.Group(copies: copies, match: group.match),
                                                    digests: downloadsHere.compactMap { queued[$0.id] }))
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
        walk(matches.map(\.group), origin: .downloads) { [weak self] carriedOut in
            guard let self else { return }
            finishReviews(carriedOut.flatMap { matches[$0].digests })
            downloadMatches = matches.indices.filter { !carriedOut.contains($0) }.map { matches[$0] }
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

    /// Runs as the vault's move (`moves.task`), so a lock or quit waits for a choice being carried out before it ejects,
    /// and no add starts while the comparison is on screen.
    private func walk(_ groups: [VaultComparison.Group], origin: VaultComparison.Origin,
                      whenDone: @escaping @MainActor (_ carriedOut: Set<Int>) async -> Void = { _ in }) {
        let comparison = VaultComparison(origin: origin) { [weak self] in await self?.playableURL(for: $0) ?? $0.url }
        self.comparison = comparison
        let generation = lockCount
        moves.task = Task {
            defer {
                comparison.end()
                if self.comparison === comparison { self.comparison = nil }
                if lockCount == generation { moves.end() }
            }
            var trashed = 0
            var carriedOut = Set<Int>()
            for (number, group) in groups.enumerated() {
                let present = group.copies.filter { FileManager.default.fileExists(atPath: $0.item.url.path) }
                guard present.count > 1 else {
                    carriedOut.insert(number)
                    continue
                }
                let current = VaultComparison.Group(copies: present, match: group.match)
                guard case .keep(let kept) = await comparison.choose(current, number: number + 1, of: groups.count),
                      lockCount == generation, phase == .open else { break }
                let outcome = await carryOut(kept, on: current)
                trashed += outcome.trashed
                if outcome.done { carriedOut.insert(number) }
            }
            guard lockCount == generation else { return }
            await whenDone(carriedOut)
            if trashed > 0 { notice = trashed == 1 ? "1 copy moved to the vault's Trash." : "\(trashed) copies moved to the vault's Trash." }
            if mode == .duplicates { findDuplicates() }
        }
    }

    /// How many copies went to the Trash, and whether the whole choice was carried out.
    private func carryOut(_ kept: Set<VaultItem.ID>, on group: VaultComparison.Group) async -> (trashed: Int, done: Bool) {
        let copies = group.copies.map(\.item)
        guard VaultDuplicates.isStillIntact(copies) else {
            message = "These copies changed since they were compared. Look again before choosing."
            return (0, false)
        }
        if kept.count == copies.count {
            await rememberKeptTogether(copies)
            return (0, true)
        }
        guard copies.contains(where: { kept.contains($0.id) }) else { return (0, false) }
        let unwanted = copies.filter { !kept.contains($0.id) }
        let trashed = await moveToTrash(unwanted).count
        return (trashed, trashed == unwanted.count)
    }
}
