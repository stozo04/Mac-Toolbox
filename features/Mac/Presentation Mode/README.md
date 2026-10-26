# Presentation Mode

**Category:** Mac  
**SF Symbol:** `rectangle.on.rectangle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Presentation Mode`)

One switch before you share your screen: hide desktop icons, hide the Dock and stay awake.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/PresentationMode/`:
- `PresentationModeView` / `PresentationModeModel` - one switch: hides desktop icons (`com.apple.finder CreateDesktop`), hides the Dock (`com.apple.dock autohide`), restarts Finder and the Dock, and holds a Keep Awake assertion. The previous values are saved first (and survive quitting Toolbox), so turning it off restores them exactly, including "was never set".
- Uses the shared `SystemDefaults` / `ProcessRestarter` (`Support/SystemDefaults.swift`).
- Tests: `MacPowerTests.swift` (`PresentationModeTests`, with fakes; not run against a real Finder and Dock).

## Implementation notes for an agent
- `defaults write com.apple.finder CreateDesktop`, Dock autohide, plus Keep Awake assertion.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
