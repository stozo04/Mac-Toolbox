import Foundation

extension VaultModel {
    func keep(_ keeper: VaultItem, in group: VaultDuplicates.Group) async {
        guard !moves.isRunning else { return }
        guard VaultDuplicates.isStillIntact(group, keeping: keeper) else {
            message = "These copies changed since they were compared. Look again before choosing."
            findDuplicates()
            return
        }
        await moveToTrash(VaultDuplicates.others(than: keeper, in: group))
    }

    func trashChosenCopies(_ chosen: Set<VaultItem.ID>) async {
        guard !moves.isRunning, let groups = visibleDuplicateGroups else { return }
        guard VaultDuplicates.groupsWithEveryCopy(of: chosen, in: groups).isEmpty else {
            message = "Leave at least one copy of each set unselected."
            return
        }
        let touched = groups.filter { group in group.copies.contains { chosen.contains($0.id) } }
        let stillIntact = touched.allSatisfy { group in
            group.copies.first { !chosen.contains($0.id) }.map { VaultDuplicates.isStillIntact(group, keeping: $0) } ?? false
        }
        guard stillIntact else {
            message = "These copies changed since they were compared. Look again before choosing."
            findDuplicates()
            return
        }
        await moveToTrash(VaultDuplicates.chosenCopies(chosen, in: touched))
    }

    func chooseExtraCopies() {
        guard let groups = visibleDuplicateGroups else { return }
        selection = Set(VaultDuplicates.extraCopies(in: groups).map(\.id))
    }
}
