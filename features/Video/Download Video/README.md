# Download Video

**Category:** Video  
**SF Symbol:** `arrow.down.to.line`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Download Video`)

Save videos from YouTube, X, TikTok and more.

## Design reference
`images/Video/Download Video.png`

## Current state
Implemented in `Sources/Toolbox/Tools/Video/DownloadVideo/`: `YtDlpCommand` (argument builder + output parser, pure), `FormatPicker` (chooses the stream for each link, pure), `YtDlpDownloader` (runs yt-dlp through `Shell.run`; `YtDlpLocator` finds the binary), `YtDlpInstaller` (downloads it, checks it against the release's `SHA2-256SUMS` and swaps it in), `DownloadVideoModel` (queue, shared singleton), `DownloadVideoView`. Unit tests in `Tests/ToolboxTests/` (`FormatPickerTests` uses real YouTube and TikTok format lists).

- Every link is probed first (`yt-dlp -J`), `FormatPicker` chooses, and the download reuses that probe (`--load-info-json`), so the choice is made per video. Ranking: tallest short side (so vertical 1080×1920 counts as 1080p), then a codec this Mac plays (H.264, HEVC, and AV1 when `VTIsHardwareDecodeSupported` says the chip decodes it; VP9 only when nothing else has that resolution, and the row then warns QuickTime can't open it), then highest frame rate, then AV1 > HEVC > H.264, then direct HTTPS over HLS, then bitrate. Audio: original language, not DRC, highest bitrate; a video stream whose audio is unknown is paired with it too. If the top stream has no sound and the site offers no separate audio, the best version with sound is taken instead, so nothing is saved silent. If the probe has no usable resolutions, yt-dlp's own sort (`-S res,fps`) decides.
- Most compatible (off by default) limits video to H.264 and audio to AAC. YouTube has no H.264 above 1080p; TikTok's 720p and 1080p are usually HEVC only.
- yt-dlp needs a JavaScript runtime for YouTube. An app opened from the Dock has no Homebrew PATH, so `YtDlpLocator.findJSRuntime` finds deno (or node) and passes `--js-runtimes`.

- yt-dlp is looked up in: `$TOOLBOX_YTDLP` (debug builds only), app bundle, `~/Library/Application Support/Toolbox/bin/yt-dlp`, Homebrew. If missing, the view offers "Install yt-dlp": it downloads the official release from GitHub together with the release's `SHA2-256SUMS` and installs the program only when its SHA-256 matches, replacing the old copy in one step so a failed install leaves it in place. The checksum catches a damaged, cut-off or swapped download; it comes from the same release as the program, so it does not protect against a release that was itself tampered with.
- Unfinished files go to a temporary folder of their own (`-P temp:<dir>`), which is removed when the download ends, fails or is cancelled, so nothing half-downloaded shows up in Downloads. Cancelling, or quitting the app, stops yt-dlp (SIGTERM, then SIGKILL).
- ffmpeg is looked up in the bundle and Homebrew; without it only ready-made MP4s can be saved.
- Every batch saves straight into `~/Downloads/`, and "Open Folder" opens it.
- "Clear" (footer) empties the list and moves the files this tool downloaded to the Trash; other files in Downloads, and videos moved into the Vault, are never touched. Tests inject `saveFolder`, `trash`, `sendToDrive` and `defaults` so they never touch the real Downloads folder, Google Drive or settings.
- "Send to Google" (footer) copies every finished download to the Google Drive folder `~/Library/CloudStorage/GoogleDrive-gates.steven@gmail.com/Other computers/My Laptop/My Stuff/Kayley/rosie/Videos/verified/` (`DriveSender`). It copies, never moves or overwrites; files already there are skipped; it fails if Drive isn't mounted. Debug builds take `$TOOLBOX_DRIVE_FOLDER` in place of the Drive folder, so a test run never uploads.
- "Add to Vault" (checkbox beside Send to Google, remembered between launches) makes Send to Google go through the Vault, using the app's one `VaultModel` (`DownloadVault` in `DownloadVault.swift`). Touch ID opens the vault (`openWithTouchID`, up to 3 prompts, no password typed; if macOS locks Touch ID after too many misses it stops and says so). Each finished video is then moved in (`moveIn`, the same checked move as a drop, which deletes the copy in Downloads) and put first in line for smart search and waited for (`makeSearchable`, at most 3 minutes each; after that it counts as "not searchable yet" and the vault indexes it the next time it is open). The vault copies go to Drive, and the vault is locked again on every way out, including a Drive failure (`lockAndConfirm`: it locks up to 3 times and believes it only when the door's answer to the lock, its state and its released claim on the vault all say locked (each check only reads the door); otherwise the footer says the Vault didn't lock. A vault another copy of Toolbox has open is left to that copy. When Touch ID never opened the vault, nothing is locked; an unlock that failed but left the vault mounted is locked at once, and the footer says if that lock failed). If Touch ID fails, isn't set up or the saved password no longer works, the videos are sent from Downloads and stay out of the vault, and the footer says why; cancelling the Touch ID prompt sends nothing. Audio and other files the vault can't hold go straight from Downloads. A video the vault refuses for a reason of its own stays in Downloads, is not sent, and its row says why; ones kept out because the vault closed are sent from Downloads. Rows in the vault show a lock and are not revealed in Finder.
- Integration test (network, opt-in, debug build): `TOOLBOX_YTDLP=... TOOLBOX_TEST_URL=<link> swift test --filter Integration`.
- Release app: `scripts/fetch-tools.sh` (downloads yt-dlp with checksum, builds LGPL static ffmpeg + ffprobe into `build/tools/`), then `scripts/make-app.sh` (assembles, signs and zips `dist/Toolbox.app`). Set `SIGN_IDENTITY` and notarize for distribution. Licenses: `THIRD_PARTY_NOTICES.md`.
- The bundled yt-dlp goes stale; "Update yt-dlp" (in the YouTube failure alert) saves a newer copy to Application Support, and the newer of the two files wins.

## Sub-features / options to build
- Paste one or more links (Paste button reads clipboard)
- Format: Best Quality / specific resolution / audio only
- Most compatible (H.264) toggle
- Per-link progress, cancel, reveal in Finder
- Add to Vault before Send to Google
- Legal note shown: only download videos you own or may save

## Implementation notes for an agent
- yt-dlp (bundled binary, run via Process) + ffmpeg for merging; keep behind a `Downloader` protocol so it is swappable.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/DownloadVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
