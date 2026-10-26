# Keep Awake

**Category:** Mac  
**SF Symbol:** `cup.and.saucer`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Keep Awake`)

Stop your Mac from sleeping during downloads, renders or talks, for as long as you choose.

## Design reference
`images/Mac/Keep Awake.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/KeepAwake/`:
- `KeepAwakeView` / `KeepAwakeModel` - duration (30 minutes to 12 hours, or no limit), keep the display on, only while on the power adapter, a live countdown; starting again replaces the timer. The model is shared so the timer survives switching tools.
- `PowerAssertions` - IOKit `PreventUserIdleSystemSleep` always, plus `PreventUserIdleDisplaySleep` when the display toggle is on; `PowerSource` watches for the adapter being unplugged (the assertion is released and resumes on reconnect).
- Tests: `MacPowerTests.swift` (including a live check that the assertions appear in `pmset -g assertions`).

## Implementation notes for an agent
- IOKit `IOPMAssertionCreateWithName` (PreventUserIdleSystemSleep / DisplaySleep).
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
