# Remove Metadata

**Category:** Images  
**SF Symbol:** `location.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Remove Metadata`)

Strip location, camera and date info from photos.

## Design reference
`images/Images/Remove Metadata.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Show what will be removed (location, camera, date)
- Select categories to strip
- Batch

## Implementation notes for an agent
- ImageIO copy without EXIF/GPS/TIFF dictionaries.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/RemoveMetadata/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
