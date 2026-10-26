# Convert Audio

**Category:** Audio  
**SF Symbol:** `arrow.triangle.2.circlepath`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Audio/Convert Audio`)

Change audio files to MP3, M4A, WAV, FLAC or AIFF.

## Design reference
`images/Audio/Convert Audio.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Target: MP3 / M4A / WAV / FLAC / AIFF
- Bitrate/sample rate
- Batch

## Implementation notes for an agent
- AVAudioFile read/write, AVAudioConverter; ffmpeg for FLAC/MP3 encode if not native.
- Put the tool's logic in `Sources/Toolbox/Tools/Audio/ConvertAudio/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
