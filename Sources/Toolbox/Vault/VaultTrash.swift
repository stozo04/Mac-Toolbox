import Foundation

/// The vault's own Trash, inside the encrypted image (`.toolbox/trash/`). macOS's Trash is no use here: for the
/// hidden vault volume it would either keep files where Finder can't reach them, or show them, with previews,
/// outside the vault. Items keep their names; Put Back returns them to the vault, Empty deletes them for good.
enum VaultTrash {
    static let folderName = "trash"

    struct Summary: Equatable {
        var count = 0
        var bytes: Int64 = 0
        var isEmpty: Bool { count == 0 }
    }

    static func folder(in privateFolder: URL) -> URL { privateFolder.appendingPathComponent(folderName) }

    static func contents(in privateFolder: URL) -> [URL] {
        let folder = folder(in: privateFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
    }

    static func summary(in privateFolder: URL) -> Summary {
        contents(in: privateFolder).reduce(into: Summary()) { summary, file in
            summary.count += 1
            summary.bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    @discardableResult
    static func move(_ file: URL, privateFolder: URL) throws -> URL {
        let folder = folder(in: privateFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = VaultMover.uniqueDestination(for: file.lastPathComponent, in: folder)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// Moves everything back into the vault. Returns the files that could not be moved.
    static func putBackAll(privateFolder: URL, into root: URL) -> [(URL, Error)] {
        contents(in: privateFolder).compactMap { file in
            do {
                try FileManager.default.moveItem(at: file, to: VaultMover.uniqueDestination(for: file.lastPathComponent, in: root))
                return nil
            } catch {
                return (file, error)
            }
        }
    }

    /// Deletes everything in the vault's Trash for good. Returns the files that could not be deleted.
    static func empty(privateFolder: URL) -> [(URL, Error)] {
        contents(in: privateFolder).compactMap { file in
            do {
                try FileManager.default.removeItem(at: file)
                return nil
            } catch {
                return (file, error)
            }
        }
    }
}
