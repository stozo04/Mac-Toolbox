# Compress Images

**Category:** Images  
**SF Symbol:** `arrow.down.right.and.arrow.up.left`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Compress Images`)

Make photos smaller without visible loss in quality.

## Design reference
`images/Images/Compress Images.png`

## Current state
Built. `CompressImagesView` (queue + 240pt options panel) is routed from `ToolWorkspace` via `ToolInput.compressImages`. Drop photos or folders, choose Low / Medium / High, Keep Format / JPEG / HEIC and whether to keep metadata (off by default), click Compress. Smaller copies go to a dated "Toolbox Compressed Images" folder in Downloads; each row shows before -> after size and percent saved, the panel shows the batch total.

- `ImageCompressor.swift` - the service. It maps the level to an encoder quality (HEIC needs a lower number than JPEG for the same look) and reuses `ImageConverter` from Convert Images (upright pixels, ICC profile, metadata handling, WebP). `ConvertSettings.dropUnusedAlpha` drops an alpha channel nothing uses, which is where most PNG savings come from.
- Keep Format: JPEG, HEIC, PNG (lossless re-save, no quantization) and WebP are re-encoded. GIF (animated), BMP, TIFF, AVIF and the like are copied unchanged and marked as such; picking JPEG or HEIC converts them.
- If the re-encoded file is not smaller, a copy of the original is saved instead (`alreadySmall`). Exception: with Keep metadata off and a GPS location in the photo, the clean copy is saved even if it is not smaller.
- Not built: pngquant-style color quantization for PNG, a free quality slider, a before/after preview.

## Implementation notes for an agent
- ImageIO re-encode with quality; optional pngquant-style quantization.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/CompressImages/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
