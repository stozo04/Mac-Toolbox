import Foundation

/// The app's version and its release history: the single source of truth.
///
/// Every PR bumps `AppVersion.current` and adds a `Release` at the TOP of `ReleaseNotes.all` (see AGENTS.md,
/// "Versioning"). `scripts/make-app.sh` reads the version from this file for Info.plist, and
/// `scripts/check-version-bump.sh` (the "Version bumped" CI job) fails if the version did not go up or the notes are missing.
enum AppVersion {
    static let current = "0.2.0"
}

struct Release: Identifiable, Equatable {
    enum Kind: String { case new = "New", improved = "Improved", fixed = "Fixed", removed = "Removed" }

    struct Change: Hashable {
        let kind: Kind
        let text: String
    }

    let version: String
    /// yyyy-MM-dd
    let date: String
    let changes: [Change]

    var id: String { version }
}

enum ReleaseNotes {
    /// Newest first. The first entry's version must equal `AppVersion.current`.
    static let all: [Release] = [
        Release(version: "0.2.0", date: "2026-11-10", changes: [
            .init(kind: .new, text: "The version now shows in the bottom-right corner. Click it to see what changed in each release."),
            .init(kind: .new, text: "Video: Record Screen, Trim Video, Video to GIF, Resize Video, Compress Video, Media Info, Mute Video, Burn In Subtitles and Extract Frames."),
            .init(kind: .new, text: "Images: Convert, Compress, Resize and Rotate Images, Blur Faces, Beautify and Annotate Screenshot, Remove Background, Remove Metadata, Redact Image and Color Picker."),
            .init(kind: .new, text: "Docs: Redact PDF and Scan Document."),
            .init(kind: .new, text: "Mac: all 14 Mac tools, from Keep Awake to Storage Explorer."),
            .init(kind: .new, text: "AI Models lists the real models on your Mac, which apps use them, and can gather them into one folder."),
            .init(kind: .improved, text: "Download Video saves to Downloads, can send to Google Drive, and Clear moves files to the Trash."),
            .init(kind: .improved, text: "Show in Finder is the same eye button everywhere."),
            .init(kind: .improved, text: "Failures are logged in more detail so they can be fixed without asking you."),
            .init(kind: .fixed, text: "Keep Awake no longer lets the Mac sleep when the power source changes."),
            .init(kind: .removed, text: "The Developer category, Replace Audio and Battery Health."),
        ]),
        Release(version: "0.1.1", date: "2026-10-26", changes: [
            .init(kind: .new, text: "App icon."),
        ]),
        Release(version: "0.1.0", date: "2026-10-26", changes: [
            .init(kind: .new, text: "First build: home screen, categories, search, favorites and dark/light mode."),
            .init(kind: .new, text: "Download Video, with yt-dlp and ffmpeg inside the app."),
            .init(kind: .new, text: "AI Models page."),
        ]),
    ]
}

/// Semantic version comparison (MAJOR.MINOR.PATCH).
enum SemVer {
    static func parse(_ s: String) -> [Int]? {
        let fields = s.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { $0.allSatisfy(\.isASCIIDigit) ? Int($0) : nil }
        return fields.count == 3 && numbers.count == 3 ? numbers : nil
    }

    static func isGreater(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return false }
        return y.lexicographicallyPrecedes(x)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
