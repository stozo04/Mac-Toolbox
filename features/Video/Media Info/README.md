# Media Info

**Category:** Video  
**SF Symbol:** `info.circle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Media Info`)

See the codec, resolution, frame rate, bitrate and metadata of videos and audio.

## Design reference
`images/Video/Media Info.png`

## Current state
Built (`Sources/Toolbox/Tools/Video/MediaInfo/`, routed through `ToolInput.mediaInfo`). Drop or choose files or folders; a list on the left, and per file a summary (size, format, duration, overall bitrate, created), one card per video / audio / other track, and a metadata card with an Open in Maps button when the file stores a location. Copy as Text and Export as JSON work on the selected file or, with several files, on all of them. Reading is pure AVFoundation (`MediaInspector`); files are only read. Not done: `ffprobe` fallback for formats AVFoundation can't open (MKV, WebM, ...), which show "Can't be read".

## Sub-features / options to build
- Codec, container, size, resolution, frame rate, bitrate, duration
- Color (SDR/HDR), audio codec
- Full metadata list, copy as text/JSON

## Implementation notes for an agent
- AVAsset track inspection; fall back to `ffprobe` for exotic formats.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/MediaInfo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
