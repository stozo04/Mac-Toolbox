# Eject All Disks

**Category:** Mac  
**SF Symbol:** `eject`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Eject All Disks`)

Safely eject every external drive, card and disk image at once before you unplug.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Built. Code is in `Sources/Toolbox/Tools/Mac/EjectAllDisks/`:
- `EjectAllDisksView` / `EjectAllDisksModel` - lists external drives, memory cards and disk images, ejects them one by one (a busy volume is reported and doesn't stop the rest) and refreshes when volumes are mounted or unmounted.
- `VolumeScanner` - local, user-visible volumes only; never the startup disk, `/System` volumes, network shares or Time Machine backups. Disk images come from `hdiutil info -plist`. Ejecting uses `NSWorkspace.unmountAndEjectDevice`.
- Tests: `MacNetworkTests.swift` (`EjectTests`).

## Implementation notes for an agent
- NSWorkspace `unmountAndEjectDevice` over mounted volumes.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
