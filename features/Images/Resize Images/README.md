# Resize Images

**Category:** Images  
**SF Symbol:** `arrow.up.left.and.arrow.down.right`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Resize Images`)

Scale photos by percentage, longest side or exact size.

## Design reference
`images/Images/Resize Images.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Images/ResizeImages/`, routed through `ToolInput.resizeImages`.
- `ImageResizer.swift` - `ImageResizePlan` (pure size arithmetic shared by the preview, the list and the saved copy) and `ImageResizer` (decode, turn upright, scale in halving steps, save in the photo's own format; WebP via the vendored encoder, TIFF/BMP via ImageIO, anything else as PNG). Photos already at the target size are copied unchanged.
- `ResizeImagesModel.swift` - queue, selected photo, settings, and `drag(_:width:height:)`, which turns a handle drag into the value of the current mode.
- `ResizeCanvas.swift` - the preview: the selected photo drawn at its new size, centered, with eight handles (four sides, four corners) and a dashed outline of the original.
- `ResizeImagesView.swift` - drop zone, queue, options panel (Percentage / Longest Side / Size, Keep proportions, Enlarge smaller images).
- Copies go to a dated `Toolbox Resized Images` folder in Downloads; originals are never touched. Camera/date/location details are kept.
- Tests: `Tests/ToolboxTests/ResizeImagesTests.swift`.

## How the drag handles behave
- The picture stays centered, so the grip under the cursor follows it exactly (an edge drag changes the size by twice the cursor's distance from the center).
- Percentage, Longest Side, and Size with Keep proportions: every grip scales the photo uniformly (a corner follows the cursor's projection on the photo's diagonal) and writes the result into that mode's field.
- Size with Keep proportions off: a side grip changes only that side; a corner changes both.
- Pulling a photo bigger than it is switches Enlarge smaller images on, so the picture follows the cursor.
- The preview scale is frozen while a grip is held and refits on release.
- Click a row in the list to preview another photo; the settings still apply to the whole batch.

## Sub-features / options
- By percentage (1-1000 %), longest side, or exact size
- Keep proportions (Size): fit inside the box; off stretches to exactly that size. Without Enlarge a side never grows.
- Enlarge smaller images
- Batch (files and folders)

## Implementation notes for an agent
- ImageIO thumbnailing / Core Graphics scaling.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/ResizeImages/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
