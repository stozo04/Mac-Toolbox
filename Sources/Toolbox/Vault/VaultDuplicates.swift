import Foundation

/// Files in the vault with exactly the same bytes, found by size first and then by SHA-256.
enum VaultDuplicates {
    struct Group: Identifiable, Equatable {
        let copies: [VaultItem]

        var id: String { copies.map(\.id).joined(separator: "|") }
        var bytesEach: Int64 { copies.first?.bytes ?? 0 }
        var extraBytes: Int64 { bytesEach * Int64(max(copies.count - 1, 0)) }
        var kind: VaultItem.Kind? { copies.first?.kind }
    }

    /// Groups of two or more identical files, biggest waste first; inside a group the oldest copy comes first.
    static func groups(in items: [VaultItem], digest: (VaultItem) throws -> Data) -> [Group] {
        let sameSize = Dictionary(grouping: items.filter { $0.bytes > 0 }, by: \.bytes).values.filter { $0.count > 1 }
        var groups: [Group] = []
        for candidates in sameSize {
            var byDigest: [Data: [VaultItem]] = [:]
            for item in candidates {
                guard let hash = try? digest(item) else { continue }
                byDigest[hash, default: []].append(item)
            }
            for copies in byDigest.values where copies.count > 1 {
                groups.append(Group(copies: copies.sorted(by: isOlder)))
            }
        }
        return groups.sorted { $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.id < $1.id }
    }

    /// The keeper and every copy are still there with the same size, so trashing the others can't lose the last copy.
    static func isStillIntact(_ group: Group, keeping keeper: VaultItem) -> Bool {
        guard group.copies.contains(keeper) else { return false }
        return group.copies.allSatisfy { copy in
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.url.path))?[.size] as? NSNumber
            return size?.int64Value == copy.bytes
        }
    }

    static func others(than keeper: VaultItem, in group: Group) -> [VaultItem] {
        group.copies.filter { $0.id != keeper.id }
    }

    static func filtered(_ groups: [Group], by filter: VaultFilter) -> [Group] {
        groups.filter { group in group.copies.first.map(filter.includes) ?? false }
    }

    private static func isOlder(_ a: VaultItem, _ b: VaultItem) -> Bool {
        a.added != b.added ? a.added < b.added : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
