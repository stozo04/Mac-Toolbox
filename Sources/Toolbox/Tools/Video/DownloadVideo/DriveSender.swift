import Foundation

/// Copies finished downloads into a Google Drive folder; the Drive desktop app does the upload.
enum DriveSender {
    struct Result: Equatable {
        var copied = 0
        var skipped = 0
        var missing = 0
    }

    enum DriveError: LocalizedError {
        case notMounted

        var errorDescription: String? { "Google Drive isn't available. Open Google Drive and try again." }
    }

    /// `$TOOLBOX_DRIVE_FOLDER` (debug builds only) stands in for Google Drive, so a test run never uploads anything.
    static var driveRoot: URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["TOOLBOX_DRIVE_FOLDER"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
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
            if !fm.fileExists(atPath: file.path) {
                result.missing += 1
                continue
            }
            if fm.fileExists(atPath: target.path) {
                result.skipped += 1
                continue
            }
            // A copy cut off halfway must never sit under the real name, or every later send would skip it.
            let partial = destination.appendingPathComponent(".toolbox-partial-" + file.lastPathComponent)
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
