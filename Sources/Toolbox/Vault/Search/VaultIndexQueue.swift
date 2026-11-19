import Foundation

/// The items asked for by name, which the search index takes before anything else it has pending.
struct VaultIndexQueue {
    private var first: [VaultItem.ID] = []

    mutating func putFirst(_ id: VaultItem.ID) {
        remove(id)
        first.insert(id, at: 0)
    }

    mutating func remove(_ id: VaultItem.ID) {
        first.removeAll { $0 == id }
    }

    mutating func carry(from old: VaultItem.ID, to new: VaultItem.ID) {
        first = first.map { $0 == old ? new : $0 }
    }

    mutating func clear() {
        first = []
    }

    /// Items asked for by name go first, even ones that arrived after this pass listed what was `pending`. `gone` hears of
    /// each one that is no longer in the vault.
    mutating func next(from pending: inout [VaultItem], in items: [VaultItem], gone: (VaultItem.ID) -> Void) -> VaultItem? {
        while let id = first.first {
            first.removeFirst()
            if let queued = pending.firstIndex(where: { $0.id == id }) { return pending.remove(at: queued) }
            if let item = items.first(where: { $0.id == id }) { return item }
            gone(id)
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }
}
