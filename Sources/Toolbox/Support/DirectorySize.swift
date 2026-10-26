import Foundation

enum DirectorySize {
    /// Disk space used by a file or by everything inside a folder. Symbolic links are not followed.
    /// Unreadable items count as zero. Call off the main thread: big folders take a while.
    static func bytes(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        func size(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard let top = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return 0 }
        if top.isSymbolicLink == true || top.isDirectory != true { return size(url) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let item = walker?.nextObject() as? URL {
            if Task.isCancelled { return total }
            total += size(item)
        }
        return total
    }
}
