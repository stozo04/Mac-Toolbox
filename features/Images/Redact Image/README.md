# Redact Image

**Category:** Images  
**SF Symbol:** `eye.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Redact Image`)

Hide names, faces and private details in an image.

## Design reference
`images/Images/Redact Image.png`

## Current state
Built. `RedactImageView` (canvas + queue strip + 240pt options panel) is routed from `ToolWorkspace` via `ToolInput.redactImage`. Drop images or folders, drag over anything to hide, pick Blur, Pixelate or Black Box and a strength, click Export Redacted. Copies keep their format and full size and go to a dated "Toolbox Redacted Images" folder in Downloads. Images with no regions are not exported (so nobody believes an untouched copy was redacted).

- `RedactImage.swift` - the service. Regions are rectangles normalized to the upright image, origin top left. Holds the drag geometry (`rect(from:to:)`, `moved`, `resized`, `hit`), Find & Cover, the Core Image renderer and `save`.
- `RedactCanvas.swift` - one `DragGesture` decides at press time: on a region side = resize, in a region = move, on empty space = draw a new one. The smallest region under the pointer wins, so a box inside a bigger one can still be reached. The picture shown is already redacted (re-rendered from a 1600 px preview on every change), so what you see is what is saved.
- `RedactImageModel.swift` - queue, regions per image, selection, find, export. Editing an exported image makes it exportable again. Delete removes the selected region (button with the Delete shortcut in the options panel).
- Find & Cover (this image or all): Find Faces (`FaceBlur.detectFaces` + margin), Find Text (Vision `.accurate`, language correction off, one region per line, padded), Find Emails, Phones & Links (the same lines kept when `NSDataDetector` finds a link or phone number, or a regex finds an email). Whole lines are covered, not single words. Found regions that mostly overlap an existing one are skipped, so running a find twice adds nothing.
- Saving: the image is decoded, turned upright, covered and written in its own format (ImageIO; WebP via the WebP encoder; PNG for formats ImageIO cannot write). Covered pixels are replaced, nothing underneath is kept. JPEG/HEIC are re-encoded at 0.92. Remove metadata (on by default) writes no EXIF/GPS/TIFF/IPTC and the copy is scanned with `MetadataStripper.scan`; if anything is left the copy is deleted and the image fails. Off keeps those details like Convert Images does. Animated GIF/PNG/WebP are refused at add time.
- Blur and pixel size follow the region's shorter side (so a line of text gets finer ones than a face), with a floor of 0.4% of the image's long side.
- Not built: undo, per-region style, rotated regions, ellipse regions, reading text in languages Vision does not support.

## Implementation notes for an agent
- Core Image pixelate / solid fill, flattened on export (no recoverable data).
- Put the tool's logic in `Sources/Toolbox/Tools/Images/RedactImage/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
