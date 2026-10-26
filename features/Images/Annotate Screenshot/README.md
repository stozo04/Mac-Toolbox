# Annotate Screenshot

**Category:** Images  
**SF Symbol:** `pencil.and.outline`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Annotate Screenshot`)

Add arrows, boxes, numbers and text to a screenshot.

## Design reference
`images/Images/Annotate Screenshot.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Arrows, boxes, numbered badges, text, highlight
- Color and stroke
- Undo/redo, copy to clipboard

## Implementation notes for an agent
- SwiftUI Canvas overlay model (shapes array), flattened on export.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/AnnotateScreenshot/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
