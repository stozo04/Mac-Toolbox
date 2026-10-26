# Trim Video

**Category:** Video  
**SF Symbol:** `scissors`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Trim Video`)

Cut the start and end of a clip without re-encoding.

## Design reference
`images/Video/Trim Video.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Filmstrip timeline with two draggable handles
- In/out time fields
- Playback preview of selection
- Re-encode fallback if keyframes do not align

## Implementation notes for an agent
- AVAssetExportSession with `timeRange` and `AVAssetExportPresetPassthrough` (no re-encode).
- Put the tool's logic in `Sources/Toolbox/Tools/Video/TrimVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
