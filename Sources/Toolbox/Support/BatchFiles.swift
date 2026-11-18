import Foundation
import UniformTypeIdentifiers

struct OutputFolderError: LocalizedError, CustomNSError {
    let parentName: String
    let underlying: Error

    private static let opening = "Couldn't create the output folder"

    var errorDescription: String? {
        "\(Self.opening) in “\(parentName)”. Check that Toolbox is allowed to save files there, and that the disk is not full."
    }

    static func clearing(_ notice: String?) -> String? {
        notice?.hasPrefix(opening) == true ? nil : notice
    }

    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying as NSError] }
}

/// Helpers for tools that convert a queue of videos into a dated folder in Downloads.
enum BatchFiles {
    /// A file's identity for spotting the same file added twice: /tmp and /private/tmp, or a link and its target, are one file.
    static func identity(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        if identity(first) == identity(second) { return true }
        guard let one = fileResourceIdentifier(of: first), let other = fileResourceIdentifier(of: second) else { return false }
        return one.isEqual(other)
    }

    private static func fileResourceIdentifier(of url: URL) -> NSObjectProtocol? {
        try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }

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

    /// The images at `url`: the file itself, or every image inside a folder (hidden files skipped).
    static func images(in url: URL) -> [URL] {
        let isImage = { (u: URL) in (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return isImage(url) ? [url] : [] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.compactMap { $0 as? URL } ?? []).filter(isImage).sorted { $0.path < $1.path }
    }

    static func gather(_ urls: [URL], files: (URL) -> [URL]) -> (found: [URL], skipped: Int) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let inside = files(url)
            if inside.isEmpty { skipped += 1 }
            found += inside
        }
        return (found, skipped)
    }

    static func skippedNotice(_ skipped: Int, because reason: String) -> String? {
        skipped == 0 ? nil : "\(skipped) item(s) \(reason) and were skipped."
    }

    static func bytes(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// A new dated folder in Downloads (or in `parent`), e.g. "Toolbox GIFs 2026-10-26 14.30.05", or "… 14.30.05 2" when that one exists.
    static func makeOutputFolder(named prefix: String, in parent: URL? = nil) throws -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let parent = parent ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = "\(prefix) \(f.string(from: Date()))"
        var dir = parent.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = parent.appendingPathComponent("\(name) \(n)")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw OutputFolderError(parentName: parent.lastPathComponent, underlying: error)
        }
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
