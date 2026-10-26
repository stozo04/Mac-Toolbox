# Fill & Flatten Forms

**Category:** Docs  
**SF Symbol:** `square.and.pencil`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Fill & Flatten Forms`)

Fill in PDF forms, add text where there are no fields, and flatten the answers so they print as-is.

## Design reference
`images/Docs/Fill and Flatten Forms.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Fill form fields
- Add text anywhere
- Flatten answers

## Implementation notes for an agent
- PDFKit `PDFAnnotation` widgets; add free text annotations where no fields exist; flatten by rendering.
- Put the tool's logic in `Sources/Toolbox/Tools/Docs/Fill&FlattenForms/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
