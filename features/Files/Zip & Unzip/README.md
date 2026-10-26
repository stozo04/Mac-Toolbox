# Zip & Unzip

**Category:** Files  
**SF Symbol:** `doc.zipper`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Files/Zip & Unzip`)

Open ZIP, RAR, 7z and TAR files, or make a ZIP, with a password if you like.

## Design reference
`images/Files/Zip and Unzip.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Open ZIP/RAR/7z/TAR
- Create ZIP with optional AES-256 password

## Implementation notes for an agent
- `/usr/bin/ditto`, `unzip`; bundled 7z/unrar for other formats.
- Put the tool's logic in `Sources/Toolbox/Tools/Files/Zip&Unzip/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
