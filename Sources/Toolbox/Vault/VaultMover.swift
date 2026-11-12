import AVFoundation
import CryptoKit
import Foundation
import ImageIO

enum VaultMoveError: LocalizedError, Equatable {
    case unsupportedType
    case insidePhotosLibrary
    case notDownloaded
    case alreadyInVault
    case link
    case copyDiffers
    case interrupted
    case changedWhileMoving
    case unreadable
    case originalKept(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType: "Only photos and videos can go in the vault."
        case .insidePhotosLibrary: "It's inside a Photos library. Export it from Photos first, then delete it there."
        case .notDownloaded: "It's in iCloud and not downloaded to this Mac yet."
        case .alreadyInVault: "It's already in the vault."
        case .link: "It's a link to a file stored somewhere else. Add the file itself."
        case .changedWhileMoving: "It changed while it was being moved, so the original was kept. Try again."
        case .interrupted: "Moving stopped when the vault locked, so the original was kept."
        case .copyDiffers: "The copy in the vault didn't match the original, so the original was kept."
        case .unreadable: "The copy in the vault couldn't be opened, so the original was kept."
        case .originalKept(let reason): "It's in the vault, but the original couldn't be deleted: \(reason)"
        }
    }
}

struct VaultMoveFailure: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let reason: String
}

enum VaultMover {
    static let photosLibraryExtension = "photoslibrary"
    private static let chunkSize = 4 * 1024 * 1024
    private static let decodeCheckPixels = 64

    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
                  url.pathExtension.lowercased() != photosLibraryExtension else { return [url] }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            return (walker?.allObjects as? [URL] ?? []).filter { VaultItem.kind(of: $0) != nil }
        }
    }

    static func check(_ source: URL, vaultRoot: URL) throws {
        let places = [source.standardizedFileURL, resolvingFolders(of: source)]
        let vaultPaths = [vaultRoot.standardizedFileURL.path, vaultRoot.resolvingSymlinksInPath().path]
        if places.contains(where: { place in vaultPaths.contains { place.path.hasPrefix($0 + "/") } }) {
            throw VaultMoveError.alreadyInVault
        }
        if places.contains(where: { $0.pathComponents.contains { $0.lowercased().hasSuffix("." + photosLibraryExtension) } }) {
            throw VaultMoveError.insidePhotosLibrary
        }
        guard VaultItem.kind(of: source) != nil else { throw VaultMoveError.unsupportedType }
        if isLink(source) { throw VaultMoveError.link }
        let values = try? source.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
            throw VaultMoveError.notDownloaded
        }
    }

    static func move(_ source: URL, into vaultRoot: URL) async throws -> URL {
        try check(source, vaultRoot: vaultRoot)
        let before = try fingerprint(source)
        let destination = uniqueDestination(for: visibleName(source.lastPathComponent), in: vaultRoot)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            try await verify(copy: destination, of: source)
            guard !Task.isCancelled, copyIsStillThere(destination, matching: source) else { throw VaultMoveError.interrupted }
            guard try fingerprint(source) == before else { throw VaultMoveError.changedWhileMoving }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        do {
            try FileManager.default.removeItem(at: source)
        } catch {
            throw VaultMoveError.originalKept(error.localizedDescription)
        }
        return destination
    }

    struct Fingerprint: Equatable {
        let size: Int
        let modified: Date?
    }

    static func fingerprint(_ url: URL) throws -> Fingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(size: (attributes[.size] as? NSNumber)?.intValue ?? -1, modified: attributes[.modificationDate] as? Date)
    }

    static func visibleName(_ name: String) -> String {
        let trimmed = String(name.drop { $0 == "." })
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    static func resolvingFolders(of url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
    }

    static func copyIsStillThere(_ copy: URL, matching original: URL) -> Bool {
        guard let copySize = try? fileSize(copy), let originalSize = try? fileSize(original) else { return false }
        return copySize == originalSize
    }

    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            number += 1
        }
        return candidate
    }

    static func verify(copy: URL, of original: URL) async throws {
        guard await opens(copy) else { throw VaultMoveError.unreadable }
        guard try fileSize(copy) == fileSize(original), try sha256(copy) == sha256(original) else {
            throw VaultMoveError.copyDiffers
        }
    }

    static func isLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK || info.st_nlink > 1
    }

    static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    static func opens(_ url: URL) async -> Bool {
        switch VaultItem.kind(of: url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) > 0 else { return false }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: decodeCheckPixels]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
        case .video:
            return (try? await AVURLAsset(url: url).load(.isReadable)) == true
        case nil:
            return false
        }
    }

    private static func fileSize(_ url: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return size?.intValue ?? -1
    }
}
