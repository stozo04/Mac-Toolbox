# Hash Generator

**Category:** Developer  
**SF Symbol:** `number`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Developer/Hash Generator`)

Create MD5, SHA-1 and SHA-256 hashes of text or files.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Text in / result out (`TextWorkspace`) with options panel. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Text or file input
- Algorithm picker
- Copy

## Implementation notes for an agent
- CryptoKit (MD5 via Insecure.MD5, SHA-1/256/512).
- Put the tool's logic in `Sources/Toolbox/Tools/Developer/HashGenerator/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
