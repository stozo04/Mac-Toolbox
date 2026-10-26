# Login & Background Items

**Category:** Mac  
**SF Symbol:** `switch.2`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Login & Background Items`)

See what starts with your Mac and runs in the background, who made it, and turn off what you don't need.

## Design reference
`images/Mac/Login and Background Items.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/LoginItems/`:
- `LoginItemsView` / `LoginItemsModel` - items grouped as Your items, All users and System services, with the app name, who made it (from its code signature), an Unsigned / Changed-since-signed badge and a switch. A link opens System Settings › Login Items.
- `LaunchItems` - reads the plists in `~/Library/LaunchAgents`, `/Library/LaunchAgents` and `/Library/LaunchDaemons`, the on/off overrides from `launchctl print-disabled`, and switches **only your own agents** with `launchctl disable/bootout` and `enable/bootstrap`. The other folders need an administrator, so they are shown locked.
- Limitation: apps added under System Settings › General › Login Items can't be listed by other apps, so they are not shown.
- Tests: `MacAppToolsTests.swift` (`LoginItemsTests`).

## Implementation notes for an agent
- ServiceManagement `SMAppService` + launchd plist enumeration.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
