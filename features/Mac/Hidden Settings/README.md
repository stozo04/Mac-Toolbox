# Hidden Settings

**Category:** Mac  
**SF Symbol:** `slider.horizontal.3`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Hidden Settings`)

Switch on useful macOS settings that aren't in System Settings, like a faster Dock or hidden files.

## Design reference
`images/Mac/Hidden Settings.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/HiddenSettings/`:
- `HiddenSettingsView` / `HiddenSettingsModel` - groups for Dock, Finder, Screenshots, Files and TextEdit, matching the design: switches, sliders (Dock delay and animation, "Default" until changed), a format menu and a folder picker. A reset arrow appears next to anything that differs from the macOS default; Reset Everything undoes all.
- `HiddenSetting` defines each key (some are inverted, e.g. `disable-shadow`); `SystemDefaults` reads and writes preferences with CFPreferences, and the affected process (Dock, Finder, SystemUIServer) is restarted once after changes settle.
- Tests: `MacPowerTests.swift` (`HiddenSettingsTests`, with a fake store and a scratch preferences domain).

## Implementation notes for an agent
- `defaults write` for Finder/Dock keys; restart affected process.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
