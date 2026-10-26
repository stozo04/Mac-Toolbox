# Mouse Fixes

**Category:** Mac  
**SF Symbol:** `computermouse`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Mouse Fixes`)

Scroll your mouse and trackpad in different directions, and make the mouse wheel faster.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Natural vs Classic for mouse and trackpad separately
- Faster mouse wheel

## Implementation notes for an agent
- `defaults`/IOHID `com.apple.swipescrolldirection`; scroll acceleration via CGEventTap.
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/MouseFixes/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
