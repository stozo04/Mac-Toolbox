# Uninstall App

**Category:** Mac  
**SF Symbol:** `trash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Uninstall App`)

Remove an app together with the caches, preferences and data it leaves behind.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/UninstallApp/`:
- `UninstallAppView` / `UninstallAppModel` - drop an app, review the app and its leftovers with sizes, tick what to remove, confirm, and everything goes to the Trash. Refuses Apple apps, Toolbox itself and running apps.
- `LeftoverScanner` - looks in `~/Library` (Application Support, Caches, Preferences, ByHost, Containers, Group Containers, Saved Application State, Logs, WebKit, HTTPStorages, Cookies, LaunchAgents, Application Scripts). Exact bundle-id matches start ticked; related (same prefix) and name-only matches are labelled and start unticked.
- Tests: `MacAppToolsTests.swift` (`UninstallAppTests`, on fake apps and a fake Library).

## Implementation notes for an agent
- Scan ~/Library for bundle-id matches (Caches, Containers, Preferences...); move to Trash.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
