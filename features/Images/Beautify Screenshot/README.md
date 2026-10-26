# Beautify Screenshot

**Category:** Images  
**SF Symbol:** `sparkles.rectangle.stack`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Beautify Screenshot`)

Put screenshots on a soft background with padding, rounded corners and a shadow.

## Design reference
`images/Images/Beautify Screenshot.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Backgrounds: gradients, wallpapers, solid, transparent
- Padding, corner radius, shadow
- Aspect ratio (e.g. 16:9)
- Window frame mockup optional

## Implementation notes for an agent
- SwiftUI/Core Graphics render: background, padding, corner radius, shadow.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/BeautifyScreenshot/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
