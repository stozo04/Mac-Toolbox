# Download Video

**Category:** Video  
**SF Symbol:** `arrow.down.to.line`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Download Video`)

Save videos from YouTube, X, TikTok and more.

## Design reference
`images/Video/Download Video.png`

## Current state
Implemented in `Sources/Toolbox/Tools/Video/DownloadVideo/`: `YtDlpCommand` (argument builder + output parser, pure), `FormatPicker` (chooses the stream for each link, pure), `YtDlpDownloader` (Process runner, `YtDlpLocator` finds/installs the binary), `DownloadVideoModel` (queue, shared singleton), `DownloadVideoView`. Unit tests in `Tests/ToolboxTests/` (`FormatPickerTests` uses real YouTube and TikTok format lists).

- Every link is probed first (`yt-dlp -J`), `FormatPicker` chooses, and the download reuses that probe (`--load-info-json`), so the choice is made per video. Ranking: tallest short side (so vertical 1080×1920 counts as 1080p), then a codec this Mac plays (H.264, HEVC, and AV1 when `VTIsHardwareDecodeSupported` says the chip decodes it; VP9 only when nothing else has that resolution, and the row then warns QuickTime can't open it), then highest frame rate, then AV1 > HEVC > H.264, then direct HTTPS over HLS, then bitrate. Audio: original language, not DRC, highest bitrate. If the probe has no usable resolutions, yt-dlp's own sort (`-S res,fps`) decides.
- Most compatible (off by default) limits video to H.264 and audio to AAC. YouTube has no H.264 above 1080p; TikTok's 720p and 1080p are usually HEVC only.
- yt-dlp needs a JavaScript runtime for YouTube. An app opened from the Dock has no Homebrew PATH, so `YtDlpLocator.findJSRuntime` finds deno (or node) and passes `--js-runtimes`.

- yt-dlp is looked up in: `$TOOLBOX_YTDLP`, app bundle, `~/Library/Application Support/Toolbox/bin/yt-dlp`, Homebrew. If missing, the view offers "Install yt-dlp" (downloads the official release from GitHub).
- ffmpeg is looked up in the bundle and Homebrew; without it only ready-made MP4s can be saved.
- Every batch saves straight into `~/Downloads/`, and "Open Folder" opens it.
- "Clear" (footer) empties the list and moves the files this tool downloaded to the Trash; other files in Downloads are never touched. Tests inject `saveFolder` and `trash` so they never touch the real Downloads folder.
- "Send to Google" (footer) copies every finished download to the Google Drive folder `~/Library/CloudStorage/GoogleDrive-gates.steven@gmail.com/Other computers/My Laptop/My Stuff/Kayley/rosie/Videos/verified/` (`DriveSender`). It copies, never moves or overwrites; files already there are skipped; it fails if Drive isn't mounted.
- Integration test (network, opt-in): `TOOLBOX_YTDLP=... TOOLBOX_TEST_URL=<link> swift test --filter Integration`.
- Release app: `scripts/fetch-tools.sh` (downloads yt-dlp with checksum, builds LGPL static ffmpeg + ffprobe into `build/tools/`), then `scripts/make-app.sh` (assembles, signs and zips `dist/Toolbox.app`). Set `SIGN_IDENTITY` and notarize for distribution. Licenses: `THIRD_PARTY_NOTICES.md`.
- The bundled yt-dlp goes stale; "Update yt-dlp" (in the YouTube failure alert) saves a newer copy to Application Support, and the newer of the two files wins.

## Sub-features / options to build
- Paste one or more links (Paste button reads clipboard)
- Format: Best Quality / specific resolution / audio only
- Most compatible (H.264) toggle
- Per-link progress, cancel, reveal in Finder
- Legal note shown: only download videos you own or may save

## Implementation notes for an agent
- yt-dlp (bundled binary, run via Process) + ffmpeg for merging; keep behind a `Downloader` protocol so it is swappable.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/DownloadVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
