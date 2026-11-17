# Redact PDF

**Category:** Docs  
**SF Symbol:** `eye.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Redact PDF`)

Black out names, numbers or whole areas so they're removed for good, not just covered up.

## Design reference
`images/Docs/Redact PDF.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Docs/RedactPDF/`:
- `RedactPDF.swift` - service, no UI. Opens a PDF (refuses non-PDFs and password-protected ones), converts PDFKit text bounds to boxes normalized to the upright page (crop box and page rotation handled), finds text (`PDFDocument.findString`, case and accent insensitive, one box per line; a page whose picture can show words the text layer does not hold is also read with Vision: one with no text layer, with a note or form entry drawn on it, or whose content paints an image, a form, a shading or a curve; a Vision match that overlaps a text-layer match is dropped, and a page Vision could not read is reported in `unreadablePages` and logged once), and exports. Export flattens every page that has a box to a 200 dpi JPEG picture with the boxes painted black into the pixels, copies the other pages as they are into a new `PDFDocument` (so title, author, outline and other document details are not carried over), and with "Keep the rest of the page searchable" runs Vision on the picture *after* the boxes are in it and lays the text back invisibly (reuses `DocumentScanner.recognizeText` / `drawInvisibleText`). The copy is written to a hidden temporary file beside the destination and checked first (page count, no title/author/subject/keywords, a black pixel in every box, no text on a flattened page when searchable is off, and the words Find & Redact covered are searched for again: a match still under a box fails the export, matches left uncovered on purpose are counted in `leftUncovered`); only then does it replace or become the destination. It refuses to write over the original, also when the destination is a hard link or another name for it (`BatchFiles.isSameFile`). `PDFPageRenderer` is an actor that draws pages from its own `PDFDocument` for the view.
- `RedactPDFModel.swift` - open/close, boxes (add, move, resize, remove, list order), zoom, Find & Redact (runs on a separate `PDFDocument` off the main thread, remembers the words it covered for the export check, and its message names pages that could not be searched), export with a save panel (default Downloads, "<name> (redacted).pdf"; `export(to:)` is the part after the panel), a small picture cache.
- `RedactPDFView.swift` - design layout: pages in a scroll view with zoom buttons and "Page x of n", boxes drawn as solid black (drag empty space to make one, drag a box to move, sides or corners to resize; geometry shared with `RedactImage`), Find & Redact card, Redactions list (click a row to jump to its box) with the searchable checkbox, count card with Export Redacted PDF; after a save it says how often a searched word is still in the copy where it was left uncovered.

Good to know: annotations on pages that are *not* redacted are kept as they are; bookmarks, attachments and form data are not carried over. Pages read with OCR can miss small or unclear words, and the tool says so after a search. The search of the copy at export reads its picture pages again (about 0.14 s a page, shown as "Checking the copy…"); a page Vision cannot read then is logged and its picture is left out of the count. Pages that are only text and straight rules are not read with OCR (it costs about a tenth of a second a page), so a word in a font whose text layer is garbled is not found on them.

Tests: `Tests/ToolboxTests/RedactPDFTests.swift` (rotation and offset crop boxes, OCR pages including a scan with a stamped page number and a word shown only by a note, unreadable pages, the text really gone from the copy, the search of the copy, details dropped, original untouched under any name).

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
