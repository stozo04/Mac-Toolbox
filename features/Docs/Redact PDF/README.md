# Redact PDF

**Category:** Docs  
**SF Symbol:** `eye.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Redact PDF`)

Black out names, numbers or whole areas so they're removed for good, not just covered up.

## Design reference
`images/Docs/Redact PDF.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Draw areas or search text to redact
- Preview
- Flatten on export

## Implementation notes for an agent
- PDFKit + render redacted pages as images (or rebuild text layer) so covered text is truly removed.
- Put the tool's logic in `Sources/Toolbox/Tools/Docs/RedactPDF/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
