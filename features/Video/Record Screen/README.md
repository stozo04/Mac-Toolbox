# Record Screen

**Category:** Video  
**SF Symbol:** `record.circle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Record Screen`)

Record a display, a window or an area, with sound.

## Design reference
`images/Video/Record Screen.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Capture a display, a window or an area
- System audio and microphone toggles
- Resolution and fps (e.g. 4K 60 fps)
- Floating control with timer and stop
- Countdown, hotkey

## Implementation notes for an agent
- ScreenCaptureKit (SCStream) + AVAssetWriter; needs Screen Recording and optionally Microphone permission.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/RecordScreen/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
