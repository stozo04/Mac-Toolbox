import Foundation

/// Copies finished downloads into a Google Drive folder; the Drive desktop app does the upload.
enum DriveSender {
    struct Result: Equatable {
        var copied = 0
        /// Already in the folder, or no longer on disk.
        var skipped = 0
    }

    enum DriveError: LocalizedError {
        case notMounted

        var errorDescription: String? { "Google Drive isn't available. Open Google Drive and try again." }
    }

    static var driveRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/GoogleDrive-gates.steven@gmail.com", isDirectory: true)
    }

    static var destination: URL {
        driveRoot.appendingPathComponent("Other computers/My Laptop/My Stuff/Kayley/rosie/Videos/verified",
                                         isDirectory: true)
    }

    /// Copies (never moves, never overwrites). `root` must exist, so a Drive that isn't mounted
    /// doesn't get a stray folder created in its place.
    static func send(_ files: [URL], to destination: URL = destination, root: URL = driveRoot) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { throw DriveError.notMounted }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var result = Result()
        for file in files {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: file.path) || fm.fileExists(atPath: target.path) {
                result.skipped += 1
                continue
            }
            try fm.copyItem(at: file, to: target)
            result.copied += 1
        }
        return result
    }
}
