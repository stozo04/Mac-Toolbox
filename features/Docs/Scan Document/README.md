# Scan Document

**Category:** Docs  
**SF Symbol:** `doc.viewfinder`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Scan Document`)

Scan paper with your iPhone or from photos. Pages are found, straightened and cleaned up.

## Design reference
`images/Docs/Scan Document.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Scan with iPhone or choose photos
- Auto-detect, straighten, clean up pages
- Reorder pages, export PDF

## Implementation notes for an agent
- VisionKit `VNDocumentCameraViewController` is iOS only; on Mac use Continuity Camera import (`NSMenuItem` Import from iPhone) or Vision rectangle detection + Core Image perspective correction on photos.
- Put the tool's logic in `Sources/Toolbox/Tools/Docs/ScanDocument/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
