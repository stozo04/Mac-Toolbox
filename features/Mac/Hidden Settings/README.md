# Hidden Settings

**Category:** Mac  
**SF Symbol:** `slider.horizontal.3`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Hidden Settings`)

Switch on useful macOS settings that aren't in System Settings, like a faster Dock or hidden files.

## Design reference
`images/Mac/Hidden Settings.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Show hidden files, show path bar
- Dock delay slider
- Reset to defaults

## Implementation notes for an agent
- `defaults write` for Finder/Dock keys; restart affected process.
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/HiddenSettings/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
