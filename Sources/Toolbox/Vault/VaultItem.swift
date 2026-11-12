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

    static func items(in root: URL) -> [VaultItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [VaultItem] = []
        for case let url as URL in walker {
            guard let kind = VaultItem.kind(of: url),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let added = values.addedToDirectoryDate ?? values.creationDate ?? .distantPast
            found.append(VaultItem(url: url, kind: kind, added: added, bytes: Int64(values.fileSize ?? 0)))
        }
        return sorted(found)
    }

    static func sorted(_ items: [VaultItem]) -> [VaultItem] {
        items.sorted { $0.added != $1.added ? $0.added > $1.added : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func neighbor(of id: VaultItem.ID, in items: [VaultItem], step: Int) -> VaultItem.ID? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + step
        return items.indices.contains(next) ? items[next].id : nil
    }
}
