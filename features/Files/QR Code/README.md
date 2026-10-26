# QR Code

**Category:** Files  
**SF Symbol:** `qrcode`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Files/QR Code`)

Make QR codes for links, text and Wi-Fi, or read codes and barcodes from images.

## Design reference
`images/Files/QR Code.png`

## Current state
Skeleton only. The tool opens from the category grid / search and shows the shared header (title, favorite star) plus the empty-state workspace: Text in / result out (`TextWorkspace`) with options panel. No processing is implemented and there is no API or network access.

## Sub-features / options to build
- Create / Read tabs
- Type: Link, Text, Wi-Fi
- Error correction level, foreground/background, size
- Copy image, export SVG/PNG

## Implementation notes for an agent
- Core Image `CIQRCodeGenerator`; Vision `VNDetectBarcodesRequest` for reading.
- Put the tool's logic in `Sources/Toolbox/Tools/Files/QRCode/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
