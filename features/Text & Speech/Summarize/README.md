# Summarize

**Category:** Text & Speech  
**SF Symbol:** `text.alignleft`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Text & Speech/Summarize`)

Summarize text and documents on device with Apple Intelligence.

## Design reference
`images/Text and Speech/Summarize.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Text in / result out (`TextWorkspace`) with options panel. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Paste text or drop document
- Length / style
- Copy

## Implementation notes for an agent
- Apple Intelligence Foundation Models framework (on device), when available.
- Put the tool's logic in `Sources/Toolbox/Tools/TextAndSpeech/Summarize/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
