# Download Video

**Category:** Video  
**SF Symbol:** `arrow.down.to.line`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Download Video`)

Save videos from YouTube, X, TikTok and more.

## Design reference
`images/Video/Download Video.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Paste-a-link input (`LinkWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Paste one or more links (Paste button reads clipboard)
- Format: Best Quality / specific resolution / audio only
- Prefer H.264 toggle (QuickTime/iPhone compatible)
- Per-link progress, cancel, reveal in Finder
- Legal note shown: only download videos you own or may save

## Implementation notes for an agent
- yt-dlp (bundled binary, run via Process) + ffmpeg for merging; keep behind a `Downloader` protocol so it is swappable.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/DownloadVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
