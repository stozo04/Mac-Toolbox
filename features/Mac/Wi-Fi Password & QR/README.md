# Wi-Fi Password & QR

**Category:** Mac  
**SF Symbol:** `wifi`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Mac/Wi-Fi Password & QR`)

Show the password of a saved Wi-Fi network and make a QR code guests can scan to join.

## Design reference
No screenshot yet (check `images/` and add one).

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Saved networks list
- Reveal password
- QR to join

## Implementation notes for an agent
- `security find-generic-password` (prompts Keychain auth) + CoreWLAN; QR via Core Image.
- Put the tool's logic in `Sources/Toolbox/Tools/Mac/Wi-FiPassword&QR/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
