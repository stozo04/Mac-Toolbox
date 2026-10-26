# Trim Video

**Category:** Video  
**SF Symbol:** `scissors`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Trim Video`)

Cut the start and end of a clip without re-encoding.

## Design reference
`images/Video/Trim Video.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Video/TrimVideo/`:
- `TrimVideoView` / `TrimVideoModel` - UI and state (shared model, so an open clip survives switching tools): preview player, filmstrip timeline with two handles and a playhead, Start/End fields, Play Selection.
- `VideoTrimmer` - `AVAssetExportSession` with the passthrough preset and `timeRange`; falls back to a highest-quality re-encode when the format can't be copied. Output is `<name> (Trimmed).<ext>` in a dated `Toolbox Videos ...` folder in Downloads.
- `TrimSelection` - start/end clamping (handles never cross); `TrimTime` - time formatting and parsing.

The screenshot only shows the empty state, so the loaded layout is designed in the same style as Record Screen.

## Implementation notes for an agent
- AVAssetExportSession with `timeRange` and `AVAssetExportPresetPassthrough` (no re-encode).
- Put the tool's logic in `Sources/Toolbox/Tools/Video/TrimVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
