# Ask a Document

**Category:** Text & Speech  
**SF Symbol:** `questionmark.bubble`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Text & Speech/Ask a Document`)

Ask questions about a PDF or document and get answers with page references.

## Design reference
`images/Text and Speech/Ask a Document.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Drag-and-drop file input (`DropZone`). Empty state: title, hint, Choose File... button, privacy note. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Chat UI with page references
- Document context

## Implementation notes for an agent
- PDFKit text extraction + on-device LLM (Foundation Models) with retrieval; cite page numbers.
- Put the tool's logic in `Sources/Toolbox/Tools/TextAndSpeech/AskaDocument/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
