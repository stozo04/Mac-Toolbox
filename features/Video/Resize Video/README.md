# Resize Video

**Category:** Video  
**SF Symbol:** `arrow.up.left.and.arrow.down.right`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Resize Video`)

Change the dimensions of videos to an exact size.

## Design reference
`images/Video/Resize Video.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Presets (4K, 1080p, 720p...) or exact width x height
- Lock aspect ratio
- Fit / fill / pad

## Implementation notes for an agent
- AVMutableVideoComposition `renderSize` + scaling transform.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/ResizeVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
