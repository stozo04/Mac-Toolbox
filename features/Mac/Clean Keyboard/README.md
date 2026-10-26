# Clean Keyboard

**Category:** Mac  
**SF Symbol:** `keyboard`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Clean Keyboard`)

Pause the keyboard for a minute so you can wipe the keys without typing gibberish.

## Design reference
`images/Mac/Clean Keyboard.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Countdown (e.g. 0:42)
- Unlock early

## Implementation notes for an agent
- CGEventTap swallowing key events (needs Accessibility/Input Monitoring).
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/CleanKeyboard/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
