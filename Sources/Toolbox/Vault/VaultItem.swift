import Foundation
import UniformTypeIdentifiers

struct VaultItem: Identifiable, Hashable {
    enum Kind: Hashable { case image, video }

    let url: URL
    let kind: Kind
    let added: Date
    let bytes: Int64

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    static func kind(of url: URL) -> Kind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return .image }
        return nil
    }
}

enum VaultLibrary {
    static let privateFolderName = ".toolbox"

    private static let itemKeys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey, .fileSizeKey]

    static func items(in root: URL) -> [VaultItem] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: itemKeys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [VaultItem] = []
        for case let url as URL in walker {
            if let item = item(at: url) { found.append(item) }
        }
        return sorted(found)
    }

    static func item(at url: URL) -> VaultItem? {
        guard let kind = VaultItem.kind(of: url),
              let values = try? url.resourceValues(forKeys: Set(itemKeys)), values.isRegularFile == true else { return nil }
        let added = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
        return VaultItem(url: url, kind: kind, added: added, bytes: Int64(values.fileSize ?? 0))
    }

    static func item(movedTo url: URL) -> VaultItem? {
        let canonicalPath = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        return item(at: canonicalPath.map { URL(fileURLWithPath: $0) } ?? url)
    }

    static func sorted(_ items: [VaultItem]) -> [VaultItem] {
        items.sorted(by: comesBefore)
    }

    static func inserting(_ item: VaultItem, into sortedItems: [VaultItem]) -> [VaultItem] {
        var items = sortedItems
        items.insert(item, at: items.firstIndex { comesBefore(item, $0) } ?? items.endIndex)
        return items
    }

    private static func comesBefore(_ first: VaultItem, _ second: VaultItem) -> Bool {
        first.added != second.added ? first.added > second.added : first.name.localizedStandardCompare(second.name) == .orderedAscending
    }

    static func neighbor(of id: VaultItem.ID, in items: [VaultItem], step: Int) -> VaultItem.ID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + step
        return items.indices.contains(next) ? items[next].id : nil
    }
}
