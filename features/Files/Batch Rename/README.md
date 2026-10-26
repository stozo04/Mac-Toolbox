# Batch Rename

**Category:** Files  
**SF Symbol:** `textformat.123`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Files/Batch Rename`)

Rename many files at once with find and replace, numbering, dates or case changes.

## Design reference
`images/Files/Batch Rename.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Find & replace, numbering, dates, case change
- Preview old -> new names
- Undo

## Implementation notes for an agent
- FileManager moves with a live preview diff.
- Put the tool's logic in `Sources/Toolbox/Tools/Files/BatchRename/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
