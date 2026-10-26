# Text to Speech

**Category:** Text & Speech  
**SF Symbol:** `speaker.wave.2`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Text & Speech/Text to Speech`)

Turn text, documents and PDFs into natural speech, and save it as audio.

## Design reference
`images/Text and Speech/Text to Speech.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Text in / result out (`TextWorkspace`) with options panel. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Voice and rate
- Text, document or PDF input
- Save as M4A

## Implementation notes for an agent
- `AVSpeechSynthesizer` writing to file via `write(_:toBufferCallback:)`.
- Put the tool's logic in `Sources/Toolbox/Tools/TextAndSpeech/TexttoSpeech/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
