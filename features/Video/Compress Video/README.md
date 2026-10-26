# Compress Video

**Category:** Video  
**SF Symbol:** `arrow.down.right.and.arrow.up.left`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Compress Video`)

Shrink video files while keeping them looking great.

## Design reference
`images/Video/Compress Video.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Quality slider with estimated size and % saved
- Target size presets (fits in WhatsApp, Discord, Mail)
- Batch, average savings stat

## Implementation notes for an agent
- AVAssetExportSession presets or AVAssetWriter with HEVC/H.264 bitrate targets.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/CompressVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
