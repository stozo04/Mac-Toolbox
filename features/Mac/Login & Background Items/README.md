# Login & Background Items

**Category:** Mac  
**SF Symbol:** `switch.2`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Login & Background Items`)

See what starts with your Mac and runs in the background, who made it, and turn off what you don't need.

## Design reference
`images/Mac/Login and Background Items.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- List with developer name and signed status
- Toggle items off

## Implementation notes for an agent
- ServiceManagement `SMAppService` + launchd plist enumeration.
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/Login&BackgroundItems/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
