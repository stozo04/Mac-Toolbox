import Foundation

/// The app's version and its release history: the single source of truth.
///
/// Every PR bumps `AppVersion.current` and adds a `Release` at the TOP of `ReleaseNotes.all` (see AGENTS.md,
/// "Versioning"). `scripts/make-app.sh` reads the version from this file for Info.plist, and
/// `scripts/check-version-bump.sh` (the "Version bumped" CI job) fails if the version did not go up or the notes are missing.
enum AppVersion {
    static let current = "0.16.4"
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
        Release(version: "0.16.4", date: "2026-11-25", changes: [
            .init(kind: .improved, text: "When Record Screen can't see your screen, the Logs page now says why, so a permission problem can be tracked down."),
        ]),
        Release(version: "0.16.3", date: "2026-11-25", changes: [
            .init(kind: .fixed, text: "A Toolbox you build yourself keeps its Screen Recording and Microphone permission after a rebuild, once a signing certificate is set up, instead of asking again every time."),
        ]),
        Release(version: "0.16.2", date: "2026-11-24", changes: [
            .init(kind: .improved, text: "Icons are in color by what they mean: on the Logs page critical is purple, errors red, warnings orange and info blue, and the count tiles, Network Speed Test tiles and info notes are colored too."),
        ]),
        Release(version: "0.16.1", date: "2026-11-24", changes: [
            .init(kind: .fixed, text: "On the home screen, each category's tools are listed right under its description, so the Docs card no longer shows Folio far down at the bottom."),
        ]),
        Release(version: "0.16.0", date: "2026-11-24", changes: [
            .init(kind: .removed, text: "The Text & Speech and Files categories and their eleven tools, none of which had been built: Transcribe, Summarize, Extract Text, Capture Text, Translate, Text to Speech, Ask a Document, QR Code, Batch Rename, Find Duplicates and Zip & Unzip."),
        ]),
        Release(version: "0.15.2", date: "2026-11-24", changes: [
            .init(kind: .improved, text: "Behind the scenes: every change is now built and tested on a Mac before it ships, and each release is built there too. Nothing looks or works differently."),
        ]),
        Release(version: "0.15.1", date: "2026-11-23", changes: [
            .init(kind: .improved, text: "Toolbox now downloads as a disk image for Apple silicon Macs: open it and drag Toolbox into Applications. The release page starts with how to install it."),
        ]),
        Release(version: "0.15.0", date: "2026-11-23", changes: [
            .init(kind: .new, text: "Video: a Scarlet card opens Scarlet, a free AI video editor you drive by talking to Claude Code or Codex. All the Video tools stay."),
            .init(kind: .new, text: "Docs is now one Folio card that opens Folio, a free PDF reader and editor. If Folio or Scarlet isn't installed, its card shows where to download it."),
            .init(kind: .removed, text: "Docs: Scan Document and Redact PDF, and the eleven PDF tools that were never built. Folio reads, signs and edits PDFs, but it does not scan paper or redact text for good."),
        ]),
        Release(version: "0.14.1", date: "2026-11-23", changes: [
            .init(kind: .removed, text: "Behind the scenes: the old online storage for the app's warnings and errors is gone, now that the log lives on your Mac. Nothing looks or works differently."),
        ]),
        Release(version: "0.14.0", date: "2026-11-23", changes: [
            .init(kind: .improved, text: "Logs: each row now says what happened without opening it, such as which page was opened, how many items were indexed or the error itself."),
            .init(kind: .new, text: "Logs: archive a log to hide it from the list and the counts. It is kept, and Show archived brings it back."),
        ]),
        Release(version: "0.13.0", date: "2026-11-23", changes: [
            .init(kind: .new, text: "Logs: a new page that lists everything the app recorded, newest first. Filter by time (1 hour to a week, or all) and by severity, see how many critical, error, warning and info events happened in that time, and open any event to see its details, copy them, or start a GitHub issue filled in with them."),
            .init(kind: .new, text: "Logs: each problem shows what the weekday log check did about it, Open, Issue open, Fix proposed, Fixed, Came back or Watching, with links to the issue and the pull request. An issue you start from a log is picked up by the next check and followed to the pull request that fixes it."),
            .init(kind: .improved, text: "The app's log now stays on your Mac, in its own file kept for 90 days. Warnings and errors are no longer sent to an online database."),
        ]),
        Release(version: "0.12.4", date: "2026-11-23", changes: [
            .init(kind: .improved, text: "Vault: when locking the Vault does not go cleanly because the normal eject was slow or refused, the app now records why and how long it waited, so the cause can be found and fixed."),
        ]),
        Release(version: "0.12.3", date: "2026-11-20", changes: [
            .init(kind: .improved, text: "Download Video: Send to Google now asks which Google Drive folder to use the first time and remembers it. Right-click the button to change the folder."),
        ]),
        Release(version: "0.12.2", date: "2026-11-19", changes: [
            .init(kind: .improved, text: "Behind the scenes: the code that runs the Vault was split into smaller parts that are easier to check. Nothing looks or works differently."),
        ]),
        Release(version: "0.12.1", date: "2026-11-19", changes: [
            .init(kind: .fixed, text: "Behind the scenes: two of the app's own checks could fail by chance on a slow machine. They no longer depend on timing."),
        ]),
        Release(version: "0.12.0", date: "2026-11-19", changes: [
            .init(kind: .new, text: "Download Video: an Add to Vault checkbox beside Send to Google opens your Vault with Touch ID, moves the videos in and makes them searchable, sends them to Google, then locks the Vault again. If Touch ID fails, the videos are still sent, just not added."),
            .init(kind: .new, text: "Vault: \"Use Touch ID to add downloads\" on the unlock screen lets Download Video open the Vault with your fingerprint."),
        ]),
        Release(version: "0.11.9", date: "2026-11-18", changes: [
            .init(kind: .fixed, text: "Vault: locking no longer freezes the app while the disk ejects; the door shows at once and the eject finishes behind it."),
            .init(kind: .fixed, text: "Vault: quitting, sleeping or locking the screen while the vault is still unlocking stops the unlock, so it is never left open behind your back."),
            .init(kind: .fixed, text: "Vault: your Mac does not go to sleep until the vault is locked, or 18 seconds have passed."),
            .init(kind: .fixed, text: "Vault: quitting waits for the vault to lock. If it can't be locked, Toolbox stays open and tells you why; quit again to quit anyway."),
            .init(kind: .fixed, text: "Vault: two copies of Toolbox can no longer open the vault at the same time or eject it from under each other."),
            .init(kind: .improved, text: "Vault: creating the vault and changing its password are never cut short. Quitting while one runs asks you to wait for it; quit again to quit anyway."),
            .init(kind: .fixed, text: "Vault: if the vault can't be ejected after a failed unlock or a crash, Toolbox says it may still be readable instead of showing it as locked."),
            .init(kind: .fixed, text: "Vault: smart search no longer fails with \"disk I/O error\" after the vault was ejected outside Toolbox."),
        ]),
        Release(version: "0.11.8", date: "2026-11-18", changes: [
            .init(kind: .fixed, text: "AI Models stops watching your disk for models when you leave the page. Before, one visit kept it looking for as long as Toolbox was open."),
            .init(kind: .improved, text: "AI Models: coming back to Toolbox looks for new models at most once every 30 seconds instead of every time."),
        ]),
        Release(version: "0.11.7", date: "2026-11-18", changes: [
            .init(kind: .fixed, text: "Vault: a file is never deleted after its copy went to an unprotected folder because the vault closed mid-move; the original is kept."),
            .init(kind: .improved, text: "Vault: each file moved in is saved to the disk before its original is deleted, so a power cut can't lose both."),
            .init(kind: .fixed, text: "Vault: if the vault is ejected from outside Toolbox, the app notices, locks, and says which files were not moved and which had just finished."),
            .init(kind: .fixed, text: "Vault: the door won't open over files left outside the vault in its open folder; it names the folder, shows it in Finder and tells you to move them."),
            .init(kind: .fixed, text: "Vault: an unlock or a vault creation that fails partway no longer leaves a half-open vault or a half-made one behind."),
            .init(kind: .fixed, text: "Vault: a second copy of Toolbox no longer ejects the vault the first copy is using; it asks you to lock it there first."),
            .init(kind: .fixed, text: "Vault: creating a vault can never delete or replace one that already exists."),
            .init(kind: .improved, text: "Vault: moving many files into a big vault is faster, and scrolling a long library uses far less memory."),
            .init(kind: .improved, text: "Vault: search tidies up after deleted files much faster."),
        ]),
        Release(version: "0.11.6", date: "2026-11-18", changes: [
            .init(kind: .fixed, text: "Dropping several files at once always tells you when some were skipped. Before, the note could vanish depending on which file loaded last."),
            .init(kind: .fixed, text: "Storage Explorer no longer freezes while it moves things to the Trash or empties it, and shows that it is working."),
            .init(kind: .fixed, text: "Storage Explorer: a list measured earlier can no longer replace a newer one."),
            .init(kind: .fixed, text: "Color Picker: the palette is always from the image you chose last, and a cleared palette stays cleared."),
            .init(kind: .fixed, text: "Trim Audio: opening another file while one is being saved no longer mixes up the two saves, and closing a file stops reading its waveform."),
            .init(kind: .fixed, text: "Video to GIF: the same video is no longer added twice when it is reached through a link or another path."),
            .init(kind: .fixed, text: "Record Screen: stopping a recording can no longer trip over a frame that is still being handled."),
        ]),
        Release(version: "0.11.4", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "Cancel now always stops the work: a cancel pressed just as a conversion, trim or download started could be missed, and it then ran to the end."),
            .init(kind: .fixed, text: "Quitting Toolbox stops conversions and downloads that are still running instead of leaving them going in the background."),
            .init(kind: .fixed, text: "A system tool that hangs can no longer leave a Mac tool waiting forever: it is stopped after a time limit, and the message says so."),
            .init(kind: .fixed, text: "Download Video: a cancelled or failed download no longer leaves half-downloaded files in your Downloads folder."),
            .init(kind: .improved, text: "Download Video: Update yt-dlp checks the download against the checksum published with it, and keeps the copy you have if anything goes wrong."),
            .init(kind: .fixed, text: "Burn In Subtitles: cancelling while the speech is being transcribed is no longer shown as a failure."),
            .init(kind: .fixed, text: "Annotate Screenshot: a blurred area can no longer show the blur of the picture you had open before."),
            .init(kind: .fixed, text: "Behind the scenes: problem reports written while earlier ones were being sent are no longer lost."),
        ]),
        Release(version: "0.11.3", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "Redact PDF: Find & Redact now also reads scanned pages that have a page number on them, and words shown in notes and pictures."),
            .init(kind: .fixed, text: "Redact PDF: if a page could not be searched, the result names the page so you can check it yourself."),
            .init(kind: .improved, text: "Redact PDF: the copy is searched again for the words you covered, and you are told how often one is still there where you left it uncovered."),
            .init(kind: .fixed, text: "Redact PDF: a copy can no longer be saved over the original through a hard link or another name for the same file."),
            .init(kind: .improved, text: "Redact Image: Find & Cover uses Black Box unless you picked a style, and warns when you blur or pixelate found text, which can sometimes be undone."),
            .init(kind: .fixed, text: "Trim Video: trimming the same video twice no longer replaces the first clip."),
            .init(kind: .fixed, text: "If the output folder in Downloads cannot be created, tools now say so once instead of failing every file."),
            .init(kind: .fixed, text: "Wi-Fi Password & QR and Annotate Screenshot now tell you when the QR code or the dragged image could not be saved."),
            .init(kind: .fixed, text: "Behind the scenes: error reports no longer include the part of a web link after the question mark."),
        ]),
        Release(version: "0.11.2", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "Behind the scenes: the app's automatic checks no longer leave settings files on your Mac or replace what you copied."),
            .init(kind: .fixed, text: "Mute Video, Burn In Subtitles and Transcribe: clearing or cancelling just as a file starts no longer quits the app."),
            .init(kind: .fixed, text: "Batch tools: files from a list you cleared no longer turn up in the folder of the next run started in the same second."),
        ]),
        Release(version: "0.11.1", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "Behind the scenes: the Keep Awake checks wait for macOS to list a new sleep block, so an automatic check no longer stops all the others."),
        ]),
        Release(version: "0.11.0", date: "2026-11-17", changes: [
            .init(kind: .new, text: "Trim Audio: drop a song or recording, drag the handles on its waveform (or type the times) and save just the part you want."),
            .init(kind: .new, text: "Trim Audio: add a fade in or fade out, hear it before you save, and keep the original format or save as MP3, M4A, WAV, FLAC or AIFF."),
            .init(kind: .new, text: "Trim Audio: with no fades and the same format, the sound is kept exactly as it was, only shorter."),
        ]),
        Release(version: "0.10.2", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "If you close the Toolbox window, clicking Toolbox in the Dock opens it again instead of showing nothing."),
        ]),
        Release(version: "0.10.1", date: "2026-11-17", changes: [
            .init(kind: .fixed, text: "Clicking Clear while a batch is working, then starting a new one, no longer lets the old batch end the new one early or start a second copy of it. This covers Mute Video, Resize Video, Video to GIF, Burn In Subtitles and the Images tools."),
        ]),
        Release(version: "0.10.0", date: "2026-11-17", changes: [
            .init(kind: .new, text: "Extract Audio: save the soundtrack of one video or a whole folder as M4A, MP3, WAV or AIFF, at the bitrate you choose."),
            .init(kind: .new, text: "Extract Audio: when a video already has AAC sound, the M4A is a straight copy, so it sounds exactly like the original."),
        ]),
        Release(version: "0.9.1", date: "2026-11-16", changes: [
            .init(kind: .fixed, text: "Vault: copies you selected in Duplicates are no longer still selected when you switch back to Library, where Delete removes files for good."),
            .init(kind: .fixed, text: "Vault: Move to Trash in Duplicates moves exactly the copies the confirmation counted, even if the duplicate list refreshes while it is open."),
        ]),
        Release(version: "0.9.0", date: "2026-11-16", changes: [
            .init(kind: .new, text: "Vault: in Duplicates, click Select, pick as many copies as you like and move them all to the vault's Trash at once. Select Extras picks every copy but the largest in each set."),
            .init(kind: .new, text: "Vault: Select All picks everything shown in the library, so you can delete many photos and videos at once."),
        ]),
        Release(version: "0.8.1", date: "2026-11-12", changes: [
            .init(kind: .fixed, text: "Vault: after a rename, Details acts on the renamed file, and Add to Search stays first in line when search restarts."),
            .init(kind: .improved, text: "Behind the scenes: updates to the build and test setup no longer need a new app version, so they can go out without an app release."),
        ]),
        Release(version: "0.8.0", date: "2026-11-12", changes: [
            .init(kind: .new, text: "Vault: right-click a photo or video and choose Details to see its size, length, resolution, codecs and sound, and to rename it."),
            .init(kind: .new, text: "Vault: Details shows whether a file is in smart search, and Add to Search puts it at the front of the queue. Press ⌘I in the viewer to open it."),
        ]),
        Release(version: "0.7.1", date: "2026-11-12", changes: [
            .init(kind: .fixed, text: "Vault: Duplicates also finds the same video saved twice under different names, like a TikTok saved once by its ID and once by its caption."),
            .init(kind: .improved, text: "Vault: each set in Duplicates is marked Exact or Likely, and likely copies show their file sizes so you can pick the better one to keep."),
        ]),
        Release(version: "0.7.0", date: "2026-11-12", changes: [
            .init(kind: .new, text: "Vault: show All, Images or Videos, each with its count, and sort videos from shortest to longest or longest to shortest."),
            .init(kind: .new, text: "Vault: a Duplicates view finds photos and videos that are exact copies of each other. Pick the one to keep and the others go to the vault's own Trash, where you can put them back or empty it."),
            .init(kind: .fixed, text: "Vault: videos with MP3 sound (common in TikTok downloads) no longer play silently, and what they say can be searched."),
            .init(kind: .improved, text: "Vault: video tiles show how long each video is."),
            .init(kind: .fixed, text: "Vault: videos always play from the beginning. Opening one from search results no longer jumps partway in, and tiles no longer show 0:00."),
        ]),
        Release(version: "0.6.2", date: "2026-11-12", changes: [
            .init(kind: .fixed, text: "Compress Video: stopping a compression no longer leaves a hidden scratch file next to your video."),
        ]),
        Release(version: "0.6.1", date: "2026-11-12", changes: [
            .init(kind: .improved, text: "Behind the scenes: the automatic build checks now use fixed, verified versions of their tools."),
        ]),
        Release(version: "0.6.0", date: "2026-11-12", changes: [
            .init(kind: .new, text: "Vault smart search: describe what you're looking for, like \"beach at sunset\", and the Vault finds the photos and videos that show it."),
            .init(kind: .new, text: "Search finds moments inside videos too, by what they show or say, and opens the video right at that moment."),
            .init(kind: .new, text: "Search runs on your Mac with EmbeddingGemma 2. It uses DigUp's copy of the model when you have DigUp, or downloads it once."),
            .init(kind: .improved, text: "The Vault's Lock button is red."),
            .init(kind: .removed, text: "Toolbox now runs on Apple silicon Macs only."),
        ]),
        Release(version: "0.5.0", date: "2026-11-12", changes: [
            .init(kind: .new, text: "Vault: a password-protected, hidden place for photos and videos. Unlock the vault door to open it."),
            .init(kind: .new, text: "Vault keeps everything in an encrypted disk image, so even in Finder it only opens with your password."),
            .init(kind: .new, text: "Adding to the Vault moves files in: each original is deleted once its copy in the vault has been checked."),
            .init(kind: .new, text: "Vault viewer: step through photos and videos with the arrow buttons or the arrow keys."),
            .init(kind: .new, text: "The Vault locks when you leave the page, lock your screen, the Mac sleeps or Toolbox quits."),
        ]),
        Release(version: "0.4.1", date: "2026-11-11", changes: [
            .init(kind: .fixed, text: "Download Video no longer gets stuck on a finished download that never shows as done."),
        ]),
        Release(version: "0.4.0", date: "2026-11-11", changes: [
            .init(kind: .improved, text: "Download Video saves each link at the highest resolution and frame rate it has (4K on YouTube, 1080p on TikTok) in a format your Mac plays."),
            .init(kind: .improved, text: "Download Video shows the resolution, frame rate and format of every download, and warns when only a format QuickTime can't open was available."),
            .init(kind: .new, text: "Download Video has a Most compatible switch for H.264 files that play on older devices and in video editors."),
            .init(kind: .fixed, text: "YouTube downloads keep finding every format when Toolbox is opened from the Dock."),
        ]),
        Release(version: "0.3.0", date: "2026-11-11", changes: [
            .init(kind: .improved, text: "AI Models shows a downloaded model that is a folder of files as one model, with its size, bits and whether it can see pictures."),
            .init(kind: .new, text: "AI Models recognizes video models such as LTX and lists them under Video creation."),
            .init(kind: .improved, text: "AI Models also watches the models folder in your home folder."),
        ]),
        Release(version: "0.2.1", date: "2026-11-11", changes: [
            .init(kind: .improved, text: "Extract Frames has a Show in Finder button once frames are saved, which opens the folder they went to."),
        ]),
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
