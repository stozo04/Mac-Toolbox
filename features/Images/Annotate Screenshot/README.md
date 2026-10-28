# Annotate Screenshot

**Category:** Images  
**SF Symbol:** `pencil.and.outline`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Annotate Screenshot`)

Add arrows, boxes, numbers and text to a screenshot.

## Design reference
`images/Images/Annotate Screenshot.png` (the home-screen card only; the editor follows the other Images tools: dark cards, 240 pt panel on the right). Think of it as Apple's version of Microsoft Paint: a toolbar of tools, a canvas, and one panel for style and export.

## Current state
Built. Code in `Sources/Toolbox/Tools/Images/AnnotateScreenshot/`:

| File | What it holds |
| --- | --- |
| `AnnotateScreenshot.swift` | `AnnotationTool`, `Annotation`, `AnnotationStyle`; `AnnotateGeometry` (hit tests, handles, resize, Shift constraints); `AnnotateRenderer` (the one drawing path for preview, thumbnail and export); `AnnotateBlurCache`; PNG/JPEG encoding and saving |
| `AnnotateScreenshotModel.swift` | Document, selection, undo/redo, crop, copy, save, keyboard shortcuts (`@Observable`, shared) |
| `AnnotateCanvas.swift` | `NSView` canvas: mouse gestures, grips, crop overlay, inline text editor, drop |
| `AnnotateCapture.swift` | Capture Area: `AreaSelector` + ScreenCaptureKit |
| `AnnotateScreenshotView.swift` | Empty state, toolbar, panel, thumbnail you can drag out |

Tools and keys: Select `V`, Arrow `A`, Line `L`, Rectangle `R`, Ellipse `E`, Text `T`, Highlighter `H`, Numbered Step `N`, Pen `P`, Blur `B` (blur or pixelate), Crop `C`.

- Input: drop or choose an image, paste with ⌘V (image data or a copied file), or Capture Area (needs Screen Recording permission; Toolbox hides itself while you select).
- Style: color (palette + custom), width, shadow, text size, fill for rectangle/ellipse, blur effect and amount. Selecting a mark loads its style into the panel; changing the panel restyles it.
- Marks are stored in image pixels; widths and text sizes are in "canvas points" (the longest side counts as 900), so they look the same on a small or a 5K screenshot.
- Blur and pixelate are drawn on the screenshot only, under every other mark, and are baked into the export.
- Undo/redo (⌘Z / ⇧⌘Z) covers drawing, moving, restyling, cropping and opening another image. Crop moves the marks with the picture.
- Output: Copy puts the full-resolution PNG on the clipboard; Save writes a new PNG or JPEG in Downloads (never over the original); the thumbnail drags into any app as a file.
- Tests: `Tests/ToolboxTests/AnnotateScreenshotTests.swift`.

## How to use Annotate Screenshot
1. Open Annotate Screenshot and drop an image, press Command-V to paste one, or click Capture Area to select part of the screen.
2. Pick a tool from the toolbar or press its key: A for Arrow, R for Rectangle, T for Text, N for Numbered Step, B for Blur and so on.
3. Set the color, width, shadow and text size. Select an annotation to move or restyle it, and press Command-Z to undo.
4. Click Copy, choose PNG or JPEG and click Save, or drag the thumbnail into any app. Your original isn't changed.

## Questions
- **How do I draw an arrow on a screenshot on Mac?** Choose Arrow (or press A) and drag from where the arrow starts to where it should point. Hold Shift to keep it straight.
- **Can I add numbered steps?** Yes. Choose Numbered Step (N) and click where each step goes. Every click adds the next number; deleting one renumbers the rest.
- **Can I hide a password or an email address?** Yes. Choose Blur (B), pick Blur or Pixelate and drag over the detail. Blur regions hide the screenshot underneath, never your other annotations. To cover many images at once, or find faces and text automatically, use Redact Image.
- **Does it upload my screenshots?** No. Everything runs on this Mac. (The "is it free" answer of the website copy is not written here; that is a product decision.)

## Not built
Zoom, rotate, and a Save As panel (Save always goes to Downloads, like the other tools). Annotations are not saved as an editable document; they exist only while the app is open.
