# Keep Awake

**Category:** Mac  
**SF Symbol:** `cup.and.saucer`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Keep Awake`)

Stop your Mac from sleeping during downloads, renders or talks, for as long as you choose.

## Design reference
`images/Mac/Keep Awake.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Duration picker (e.g. 1 Hour)
- Keep display on toggle
- Only on power adapter toggle
- Countdown timer; starting again replaces timer

## Implementation notes for an agent
- IOKit `IOPMAssertionCreateWithName` (PreventUserIdleSystemSleep / DisplaySleep).
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/KeepAwake/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
