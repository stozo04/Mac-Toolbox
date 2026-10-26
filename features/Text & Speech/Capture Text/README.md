# Capture Text

**Category:** Text & Speech  
**SF Symbol:** `viewfinder`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Text & Speech/Capture Text`)

Select any area of the screen and copy the text in it.

## Design reference
`images/Text and Speech/Capture Text.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Select screen area
- Auto-copy to clipboard with confirmation

## Implementation notes for an agent
- ScreenCaptureKit region capture + Vision OCR; global hotkey.
- Put the tool's logic in `Sources/Toolbox/Tools/TextAndSpeech/CaptureText/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
