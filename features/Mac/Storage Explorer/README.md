# Storage Explorer

**Category:** Mac  
**SF Symbol:** `internaldrive`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Storage Explorer`)

See what's filling your disk, find the usual space hogs and clear them out safely.

## Design reference
`images/Mac/Storage Explorer.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Categories with sizes
- Clear selected safely (Trash)

## Implementation notes for an agent
- FileManager size scan of known hogs (Xcode DerivedData, caches, Movies...).
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/StorageExplorer/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
