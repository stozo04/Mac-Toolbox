# Burn In Subtitles

**Category:** Video  
**SF Symbol:** `captions.bubble`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Burn In Subtitles`)

Add captions to a video from an SRT file or automatic transcription.

## Design reference
`images/Video/Burn In Subtitles.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Source: SRT file or automatic transcription
- Style: font, size, color, background, position
- Preview before export

## Implementation notes for an agent
- AVFoundation composition + Core Animation text layers, or ffmpeg `subtitles` filter. Auto mode reuses the Transcribe engine (Speech framework).
- Put the tool's logic in `Sources/Toolbox/Tools/Video/BurnInSubtitles/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
