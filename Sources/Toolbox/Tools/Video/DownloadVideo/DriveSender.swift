import Foundation

/// Copies finished downloads into a Google Drive folder; the Drive desktop app does the upload.
enum DriveSender {
    struct Result: Equatable {
        var copied = 0
        var skipped = 0
        var missing = 0
    }

    enum DriveError: LocalizedError {
        case noFolderChosen
        case notMounted

        var errorDescription: String? {
            switch self {
            case .noFolderChosen: "Choose a Google Drive folder first."
            case .notMounted: "Google Drive isn't available. Open Google Drive and try again."
            }
        }
    }

    static let partialPrefix = ".toolbox-partial-"
    static let folderKey = "downloadVideo.driveFolder"

    /// Where the Open panel starts: the folder macOS mounts Google Drive and other cloud drives in.
    static var cloudStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    /// The folder the person chose. `$TOOLBOX_DRIVE_FOLDER` (debug builds only) stands in for it, so a test run never uploads anything.
    static func chosenFolder(in defaults: UserDefaults = .standard,
                             environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        #if DEBUG
        if let override = environment["TOOLBOX_DRIVE_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func choose(_ folder: URL, in defaults: UserDefaults = .standard) {
        defaults.set(folder.path, forKey: folderKey)
    }

    static func send(_ files: [URL], defaults: UserDefaults = .standard) throws -> Result {
        guard let folder = chosenFolder(in: defaults) else { throw DriveError.noFolderChosen }
        return try send(files, to: folder, root: folder)
    }

    /// Copies (never moves, never overwrites). `root` must exist, so a Drive that isn't mounted
    /// doesn't get a stray folder created in its place.
    static func send(_ files: [URL], to destination: URL, root: URL) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { throw DriveError.notMounted }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let leftovers = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
        for name in leftovers where name.hasPrefix(partialPrefix) { try? fm.removeItem(at: destination.appendingPathComponent(name)) }
        var result = Result()
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: file.path) {
                result.missing += 1
                continue
            }
            if fm.fileExists(atPath: target.path) {
                result.skipped += 1
                continue
            }
            // A copy cut off halfway must never sit under the real name, or every later send would skip it.
            let partial = destination.appendingPathComponent(partialPrefix + file.lastPathComponent)
            try? fm.removeItem(at: partial)
            do {
                try fm.copyItem(at: file, to: partial)
                try fm.moveItem(at: partial, to: target)
            } catch {
                try? fm.removeItem(at: partial)
                throw error
            }
            result.copied += 1
        }
        return result
    }
}
