# Convert Images

**Category:** Images  
**SF Symbol:** `arrow.triangle.2.circlepath`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Convert Images`)

Save photos as HEIC, WebP, JPG, JPEG or PNG.

## Design reference
`images/Images/Convert Images.png`

## Current state
Built (`Sources/Toolbox/Tools/Images/ConvertImages/`, routed through `ToolInput.convertImages`). Queue of images (files or folders; anything macOS can read, including HEIC, WebP, JPEG, PNG, TIFF, GIF, BMP). Targets: HEIC, WebP, JPG, JPEG, PNG, from any source, same format included. Options: Format, Quality (HEIC, WebP, JPG, JPEG), Lossless (WebP only), Keep metadata. "Convert" writes into a new "Toolbox Converted Images" folder in Downloads, same file names with the new extension.

- HEIC, JPG, JPEG and PNG are written by ImageIO. macOS cannot write WebP, so `Sources/CWebP/` holds libwebp 1.6.0's encoder (vendored, BSD-3-Clause, no network) and `WebPEncoder` wraps it. WebP is written in sRGB.
- Photos are turned upright (EXIF orientation applied to the pixels, tag reset). JPG/JPEG cannot hold transparency, so see-through areas become white; PNG, WebP and HEIC keep it.
- Keep metadata copies Exif, GPS, TIFF (camera) and IPTC details, minus the old size and orientation; WebP gets them as an EXIF chunk. Off removes them.
- Not done: TIFF as a target (the original brief listed it, the request did not), animated GIF/WebP (first frame only), per-file format choice.

## Implementation notes for an agent
- ImageIO `CGImageDestination`.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/ConvertImages/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
