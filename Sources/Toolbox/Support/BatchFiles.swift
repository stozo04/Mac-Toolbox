import Foundation
import UniformTypeIdentifiers

/// Helpers for tools that convert a queue of videos into a dated folder in Downloads.
enum BatchFiles {
    /// The videos at `url`: the file itself, or every video inside a folder (hidden files skipped).
    static func videos(in url: URL) -> [URL] {
        let isVideo = { (u: URL) in (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .movie) ?? false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isVideo(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.compactMap { $0 as? URL } ?? []).filter(isVideo).sorted { $0.path < $1.path }
    }

    /// A new dated folder in Downloads, e.g. "Toolbox GIFs 2026-10-26 14.30.05".
    static func makeOutputFolder(named prefix: String) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = downloads.appendingPathComponent("\(prefix) \(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// "Clip.gif", or "Clip 2.gif" when the name is taken.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return url
    }
}
