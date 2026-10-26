# Translate

**Category:** Text & Speech  
**SF Symbol:** `character.bubble`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Text & Speech/Translate`)

Translate text, documents and subtitles on device, keeping their formatting and timing.

## Design reference
`images/Text and Speech/Translate.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Text in / result out (`TextWorkspace`) with options panel. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Source/target language
- Text, documents, subtitle files (keep timing)

## Implementation notes for an agent
- Apple Translation framework (on device).
- Put the tool's logic in `Sources/Toolbox/Tools/TextAndSpeech/Translate/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
