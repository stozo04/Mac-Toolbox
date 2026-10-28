# Crop & Rotate Video

**Category:** Video  
**SF Symbol:** `crop.rotate`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Crop & Rotate Video`)

Crop, rotate and flip a video.

## Design reference
`images/Video/Crop and Rotate.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Crop rectangle with aspect presets
- Rotate 90/180/270
- Flip horizontal / vertical

## Implementation notes for an agent
- AVMutableVideoComposition with `CGAffineTransform` and `cropRect`.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/Crop&RotateVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
