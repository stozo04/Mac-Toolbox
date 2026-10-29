# Scan Document

**Category:** Docs  
**SF Symbol:** `doc.viewfinder`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Docs/Scan Document`)

Scan paper with your iPhone or from photos. Pages are found, straightened and cleaned up.

## Design reference
`images/Docs/Scan Document.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Docs/ScanDocument/`:
- `DocumentScanner.swift` - service, no UI: page detection (`VNDetectDocumentSegmentationRequest` and `VNDetectRectanglesRequest`, the one with the squarer corners wins), `CIPerspectiveCorrection`, the three looks (paper brightness is estimated and divided out, then color / gray / threshold), Vision OCR, and the PDF writer (JPEG passed through for Color and Grayscale, lossless 8-bit gray for Black & White, hidden text drawn with the invisible text mode).
- `ScanDocumentModel.swift` - pages, reorder, rotate, remove, thumbnails per look, Save PDF (save panel, default Downloads).
- `ScanDocumentView.swift` - design layout: pages grid (drag to reorder, hover to rotate or remove, double-click to preview), Scan card (Look, Page size, Make text searchable), Pages card with Save PDF.
- `ContinuityCamera.swift` - the "Import from iPhone or iPad" menu (Take Photo, Scan Documents) through AppKit's services requestor; scans arrive as PDFs, photos as images.

Inputs: photos, PDFs and folders by drop or Choose Photos; iPhone scans and photos by Scan with iPhone. A PDF is taken as already flat (no edge search). If no edges are found the whole photo is used and a note says so.

Not verified on a real iPhone: the Continuity Camera menu needs a nearby iPhone signed in to the same Apple Account.

Tests: `Tests/ToolboxTests/ScanDocumentTests.swift`.

## Implementation notes for an agent
- VisionKit `VNDocumentCameraViewController` is iOS only; on Mac use Continuity Camera import (`NSMenuItem` Import from iPhone) or Vision rectangle detection + Core Image perspective correction on photos.
- Put the tool's logic in `Sources/Toolbox/Tools/Docs/ScanDocument/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
