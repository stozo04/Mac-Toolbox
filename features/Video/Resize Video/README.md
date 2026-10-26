# Resize Video

**Category:** Video  
**SF Symbol:** `arrow.up.left.and.arrow.down.right`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Resize Video`)

Change the dimensions of videos to an exact size.

## Design reference
`images/Video/Resize Video.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Video/ResizeVideo/`:
- `ResizeVideoView` / `ResizeVideoModel` - UI and state (shared model, so the queue survives switching tools): drop zone (files or folders), a queue with per-file progress and size, and the 240pt options panel (size preset or custom width/height with swap, keep aspect ratio with Add black bars / Crop to fill / Fit within size, format H.264 or HEVC). Presets and the width/height fields stay in sync.
- `VideoResizer` - `AVMutableVideoComposition` (`renderSize` plus a scaling/translation transform that includes the track's `preferredTransform`) exported with `AVAssetExportSession` as MP4. Output is `<name> (WxH).mp4` in a dated `Toolbox Videos ...` folder in Downloads.
- `ResizeSettings` / `ResizePlan` - pure layout logic: even-size rounding, bars, crop, fit-within, stretch.

Shared helpers (folder scanning, dated output folder, unique names) live in `Sources/Toolbox/Support/BatchFiles.swift`, also used by Video to GIF.

Tests: `Tests/ToolboxTests/ResizeVideoTests.swift` (layout maths, preset sync, a real resize in both codecs, and a pixel check of the black bars).

Unlike Video to GIF, videos can be enlarged, since the goal is an exact size.

## Implementation notes for an agent
- AVMutableVideoComposition `renderSize` + scaling transform.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/ResizeVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
