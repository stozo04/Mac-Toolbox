# Uninstall App

**Category:** Mac  
**SF Symbol:** `trash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Uninstall App`)

Remove an app together with the caches, preferences and data it leaves behind.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Show leftovers with sizes
- Select and remove

## Implementation notes for an agent
- Scan ~/Library for bundle-id matches (Caches, Containers, Preferences...); move to Trash.
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/UninstallApp/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
