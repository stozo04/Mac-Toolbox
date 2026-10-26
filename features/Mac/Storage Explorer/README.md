# Storage Explorer

**Category:** Mac  
**SF Symbol:** `internaldrive`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Storage Explorer`)

See what's filling your disk, find the usual space hogs and clear them out safely.

## Design reference
`images/Mac/Storage Explorer.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/StorageExplorer/`:
- `StorageExplorerView` / `StorageExplorerModel` - two tabs. **Space Hogs** lists iOS Simulators, App Caches (Homebrew excluded so it isn't counted twice), Homebrew Downloads, Docker, iPhone and iPad Backups, Trash and Old Downloads (added more than 90 days ago), with startup-disk usage (used / purgeable / free) and a total. **Explore** browses folder sizes from the home folder down.
- `SpaceHog` / `StorageScanner` / `StorageCleaner` - clearing moves items to the Trash; only the Trash itself is deleted for good, after a confirmation. Every item must sit inside its category's folder or it is refused. Docker and Simulators are not cleared here (the owning app should). Unreadable folders show a Full Disk Access hint.
- Tests: `StorageExplorerTests.swift` (on a temporary fake home folder).

## Implementation notes for an agent
- FileManager size scan of known hogs (Xcode DerivedData, caches, Movies...).
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
