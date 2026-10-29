# Redact PDF

**Category:** Docs  
**SF Symbol:** `eye.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Redact PDF`)

Black out names, numbers or whole areas so they're removed for good, not just covered up.

## Design reference
`images/Docs/Redact PDF.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Docs/RedactPDF/`:
- `RedactPDF.swift` - service, no UI. Opens a PDF (refuses non-PDFs and password-protected ones), converts PDFKit text bounds to boxes normalized to the upright page (crop box and page rotation handled), finds text (`PDFDocument.findString`, case and accent insensitive, one box per line; pages with no text layer are read with Vision instead), and exports. Export flattens every page that has a box to a 200 dpi JPEG picture with the boxes painted black into the pixels, copies the other pages as they are into a new `PDFDocument` (so title, author, outline and other document details are not carried over), and with "Keep the rest of the page searchable" runs Vision on the picture *after* the boxes are in it and lays the text back invisibly (reuses `DocumentScanner.recognizeText` / `drawInvisibleText`). The copy is written to a hidden temporary file beside the destination and checked first (page count, no title/author/subject/keywords, a black pixel in every box, no text on a flattened page when searchable is off); only then does it replace or become the destination. It refuses to write over the original. `PDFPageRenderer` is an actor that draws pages from its own `PDFDocument` for the view.
- `RedactPDFModel.swift` - open/close, boxes (add, move, resize, remove, list order), zoom, Find & Redact (runs on a separate `PDFDocument` off the main thread), export with a save panel (default Downloads, "<name> (redacted).pdf"), a small picture cache.
- `RedactPDFView.swift` - design layout: pages in a scroll view with zoom buttons and "Page x of n", boxes drawn as solid black (drag empty space to make one, drag a box to move, sides or corners to resize; geometry shared with `RedactImage`), Find & Redact card, Redactions list (click a row to jump to its box) with the searchable checkbox, count card with Export Redacted PDF.

Good to know: annotations on pages that are *not* redacted are kept as they are; bookmarks, attachments and form data are not carried over. Pages read with OCR (no text layer) can miss small or unclear words, and the tool says so after a search.

Tests: `Tests/ToolboxTests/RedactPDFTests.swift` (rotation and offset crop boxes, OCR pages, the text really gone from the copy, details dropped, original untouched).

## Sub-features / options to build
- Draw areas or search text to redact
- Preview
- Flatten on export

## Implementation notes for an agent
- PDFKit + render redacted pages as images (or rebuild text layer) so covered text is truly removed.
- Put the tool's logic in `Sources/Toolbox/Tools/Docs/RedactPDF/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
