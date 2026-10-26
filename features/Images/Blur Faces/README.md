# Blur Faces

**Category:** Images  
**SF Symbol:** `face.dashed`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Blur Faces`)

Find faces in photos and blur, pixelate or black them out.

## Design reference
`images/Images/Blur Faces.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Detected faces list; toggle each
- Style: blur / pixelate / black out
- Strength slider
- Batch

## Implementation notes for an agent
- Vision `VNDetectFaceRectanglesRequest` + Core Image blur/pixelate.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/BlurFaces/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
