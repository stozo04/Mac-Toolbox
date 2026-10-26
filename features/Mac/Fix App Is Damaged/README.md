# Fix "App Is Damaged"

**Category:** Mac  
**SF Symbol:** `exclamationmark.triangle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Fix "App Is Damaged"`)

Check who made an app that won't open, then clear the download quarantine so macOS lets it run.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/FixDamagedApp/`:
- `FixDamagedAppView` / `FixDamagedAppModel` - drop an app to see who made it (code signature), whether the signature is intact, what Gatekeeper (`spctl --assess`) says and whether it carries the download quarantine flag, with a plain-language verdict. Clearing the quarantine asks for confirmation first.
- `AppInspector` / `Quarantine` - removes `com.apple.quarantine` from the app and every file inside it with `removexattr` (the app itself isn't changed). System apps are refused.
- Shared: `Support/CodeSignInfo.swift` (also used by Login & Background Items).
- Tests: `MacAppToolsTests.swift` (`FixDamagedAppTests`, `CodeSignInfoTests`).

## Implementation notes for an agent
- `codesign -dv`/`spctl` to show who made the app, then `xattr -dr com.apple.quarantine`.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
