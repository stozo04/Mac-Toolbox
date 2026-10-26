# Record Audio

**Category:** Audio  
**SF Symbol:** `mic`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Audio/Record Audio`)

Record your voice, then transcribe it on device.

## Design reference
`images/Audio/Record Audio.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Live tool with options panel on the left and status/action on the right (`LiveWorkspace`). No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Input device picker
- Live waveform and timer
- Save as M4A/WAV
- Transcribe after recording

## Implementation notes for an agent
- AVAudioRecorder / AVAudioEngine; Microphone permission. Optional on-device transcription via Speech framework.
- Put the tool's logic in `Sources/Toolbox/Tools/Audio/RecordAudio/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
