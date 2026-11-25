import Foundation

/// What one add did with the files that had a copy in the vault already.
struct VaultAddTally: Equatable {
    var added = 0
    var replaced = 0
    var keptAsTheyWere = 0
    var keptBoth = 0
    var reviewed: Bool { replaced + keptAsTheyWere + keptBoth > 0 }

    var summary: String {
        "\(added) added, \(replaced) replaced with a better copy, \(keptAsTheyWere) kept as they were, \(keptBoth) kept both"
    }
}

extension VaultModel {
    /// Checks the files for copies already in the vault, moves in the ones without, then asks about each set of copies.
    func add(_ urls: [URL]) {
        guard phase == .open, !isLocking else { return }
        guard !moves.isRunning else {
            message = VaultMoveError.busy.localizedDescription
            return
        }
        let files = VaultMover.expand(urls)
        guard !files.isEmpty else { return }
        moveFailures = []
        let id = moves.begin(files)
        guard !lockIfClosedFromOutside() else { return }
        moves.task = Task {
            var tally = VaultAddTally()
            isCheckingForDuplicates = true
            let groups = await duplicatesOfIncoming(files)
            isCheckingForDuplicates = false
            guard moves.isCurrent(id) else { return }
            let matched = Set(groups.flatMap(\.copies).map(\.url)).intersection(files)
            moves.setAside(files.filter(matched.contains))
            for file in files where !matched.contains(file) {
                if Task.isCancelled || !disk.isOpen { break }
                if await moveOne(file, id: id) != nil { tally.added += 1 }
                guard moves.isCurrent(id) else { break }
            }
            if !Task.isCancelled, disk.isOpen, moves.isCurrent(id) {
                await review(groups, incoming: matched, id: id, tally: &tally)
            }
            Log.info("Moved into vault", category: VaultLog.category,
                     ["count": String(files.count), "failed": String(moveFailures.count), "reviewed": String(groups.count)])
            guard moves.isCurrent(id), !lockIfClosedFromOutside() else { return }
            if tally.reviewed { notice = tally.summary }
            if !isLocking { reload() }
            refreshIndex()
            moves.end()
        }
    }

    /// Moves one file in and shows it. Nil when it is not in the vault; a copy whose original couldn't be deleted is in.
    @discardableResult
    func moveOne(_ file: URL, id: UUID) async -> URL? {
        moves.takeUp(file)
        var inside: URL?
        do {
            let moved = try await moveFile(file, root)
            inside = moved
            if moves.isCurrent(id) { showMovedIn(moved) } else { correctReportIfMovedAfterAll(file) }
        } catch {
            guard moves.isCurrent(id) else { return nil }
            moveFailures.append(VaultMoveFailure(name: file.lastPathComponent, reason: error.localizedDescription))
            if VaultNotices.isUnexpected(error) { VaultLog.failure("Vault move failed", error, file: file) }
            if case VaultMoveError.originalKept(_, let copy) = error { inside = copy }
        }
        if moves.isCurrent(id) { moves.settled(file) }
        return inside
    }

    private func duplicatesOfIncoming(_ files: [URL]) async -> [VaultDuplicates.Group] {
        let incoming = files.filter { (try? VaultMover.check($0, vaultRoot: root)) != nil }.compactMap(VaultLibrary.item(at:))
        guard !incoming.isEmpty else { return [] }
        let vault = items
        let lengths = await lengths(of: vault + incoming)
        let groups = await matchCache.matches(for: incoming, in: vault, lengths: lengths, remembered: duplicatesStore)
        return groups ?? []
    }

    private func review(_ groups: [VaultDuplicates.Group], incoming: Set<URL>, id: UUID, tally: inout VaultAddTally) async {
        let comparison = VaultComparison(origin: .adding) { [weak self] in await self?.playableURL(for: $0) ?? $0.url }
        self.comparison = comparison
        defer {
            comparison.end()
            if self.comparison === comparison { self.comparison = nil }
        }
        for (number, group) in groups.enumerated() {
            guard moves.isCurrent(id), disk.isOpen else { return }
            let present = group.copies.filter { FileManager.default.fileExists(atPath: $0.url.path) }
            let copies = present.filter { !incoming.contains($0.url) }.map { VaultComparison.Copy(item: $0, place: .vault) }
                + present.filter { incoming.contains($0.url) }.map { VaultComparison.Copy(item: $0, place: .incoming) }
            let arriving = copies.filter(\.isIncoming)
            guard !arriving.isEmpty else { continue }
            guard copies.count > 1 else {
                for copy in arriving where await moveOne(copy.item.url, id: id) != nil { tally.added += 1 }
                continue
            }
            let shown = VaultComparison.Group(copies: copies, match: group.match)
            guard case .keep(let kept) = await comparison.choose(shown, number: number + 1, of: groups.count),
                  moves.isCurrent(id) else { return }
            await carryOut(kept, on: shown, id: id, tally: &tally)
        }
    }

    private func carryOut(_ kept: Set<VaultItem.ID>, on group: VaultComparison.Group, id: UUID,
                          tally: inout VaultAddTally) async {
        guard VaultDuplicates.isStillIntact(group.copies.map(\.item)) else {
            message = "These copies changed since they were compared. The new one was left where it was."
            group.copies.filter(\.isIncoming).forEach { moves.settled($0.item.url) }
            return
        }
        if kept.count == group.copies.count { await rememberKeptTogether(group.copies.map(\.item)) }
        var keptInside = group.copies.contains { !$0.isIncoming && kept.contains($0.id) }
        var arrived = 0
        for copy in group.copies where copy.isIncoming {
            guard kept.contains(copy.id) else {
                moves.settled(copy.item.url)
                tally.keptAsTheyWere += 1
                continue
            }
            if await moveOne(copy.item.url, id: id) != nil {
                keptInside = true
                arrived += 1
            }
        }
        let unwanted = group.copies.filter { !$0.isIncoming && !kept.contains($0.id) }.map(\.item)
        let trashed = keptInside && !unwanted.isEmpty ? await moveToTrash(unwanted) : []
        if !group.copies.contains(where: { !$0.isIncoming }) {
            tally.added += arrived
        } else if trashed.isEmpty {
            tally.keptBoth += arrived
        } else {
            tally.replaced += arrived
        }
    }

    func rememberKeptTogether(_ copies: [VaultItem]) async {
        guard let duplicatesStore else { return }
        do {
            try duplicatesStore.keepTogether(try await matchCache.digests(of: copies))
        } catch {
            VaultLog.failure("Vault duplicates memory failed", error)
            message = "Kept them all, but the vault couldn't remember this choice, so they may be suggested again."
        }
    }
}
