# Convert Video

**Category:** Video  
**SF Symbol:** `arrow.triangle.2.circlepath`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Convert Video`)

Change videos to MP4, MOV, WebM or M4V.

## Design reference
`images/Video/Convert Video.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Target: MP4 / MOV / WebM / M4V
- Batch conversion
- Keep or re-encode

## Implementation notes for an agent
- AVAssetExportSession / AVAssetWriter for MP4, MOV, M4V; ffmpeg for WebM. Show estimated size.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/ConvertVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
