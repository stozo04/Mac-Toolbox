# Rotate Images

**Category:** Images  
**SF Symbol:** `rotate.right`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Rotate Images`)

Rotate or flip many photos at once.

## Design reference
`images/Images/Rotate Images.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Images/RotateImages/`, routed through `ToolInput.rotateImages`.
- `ImageRotator.swift` - `RotateSettings` (the change as one of the eight turn/mirror states; each button acts on what is on screen, so they can be pressed in any order) and `ImageRotator` (decode, turn upright from the file's own orientation tag, move the pixels, save in the photo's own format; WebP via the vendored encoder, TIFF/BMP via ImageIO, anything else as PNG). The saved copy is reopened and its shape checked.
- `RotateImagesModel.swift` - queue, selected photo, settings and the live preview. The preview is made by the same pixel mover that writes the copies.
- `RotateImagesView.swift` - drop zone, preview, queue, options panel (Rotate left/right, Flip horizontal/vertical, Result line, Reset).
- Copies go to a dated `Toolbox Rotated Images` folder in Downloads; originals are never touched. Camera/date/location details are kept; the orientation tag is not (the pixels are already upright).
- Rotate stays disabled while the Result line reads "No change".
- Tests: `Tests/ToolboxTests/RotateImagesTests.swift`.

## Sub-features / options
- Rotate left or right in 90 degree steps
- Flip horizontal or vertical
- Result line, preview of the selected photo, Reset
- Batch (files and folders)

## Notes
- Pixels are moved, not resampled. JPEG and HEIC are encoded again (JPEG 95, HEIC 90), which can add a little compression.
- Animated GIFs are refused.
- Everything runs on device; never modify the original file.
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
