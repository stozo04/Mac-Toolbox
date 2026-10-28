# Beautify Screenshot

**Category:** Images  
**SF Symbol:** `sparkles.rectangle.stack`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Beautify Screenshot`)

Put screenshots on a soft background with padding, rounded corners and a shadow.

## Design reference
`images/Images/Beautify Screenshot.png` (the catalog card). The workspace follows the screenshot in the request: Preview with a size badge, Options (Background, Aspect ratio, Padding, Corner radius, Shadow), Files list, and the Framed count with Beautify.

## Current state
Built (`Sources/Toolbox/Tools/Images/BeautifyScreenshot/`, routed through `ToolInput.beautifyScreenshot`). Queue of screenshots (files or folders). The preview shows the selected screenshot framed with the current options. "Beautify" writes a PNG of each into a new "Toolbox Beautified Screenshots" folder in Downloads, same file name.

- Background: Soft Light, Graphite and Accent Blue gradients; Custom Color; Image (fills the canvas, cropped from the middle); Transparent (the preview shows a checkerboard).
- Aspect ratio: Auto (the screenshot plus its padding), 16:9 for X, 1:1 Square, 4:5 for Instagram, 9:16 for Stories. The canvas only grows to reach the ratio; nothing is cropped.
- Padding: S to L, 2% to 22% of the screenshot's shorter side.
- Corner radius: 0 to 40 "pt", roughly @2x at the screenshot's size, so it scales with the screenshot.
- Shadow: None, Soft, Strong, measured from the shorter side.
- Output is PNG at the screenshot's own resolution, with the padding added. Nothing is scaled up. The original is never touched.

## Implementation
- `BeautifyScreenshot.swift`: framing with Core Graphics (gradient, colour or image fill, rounded clip, shadow drawn under a solid shape), canvas sizing, and saving. Orientation is applied as in Convert Images.
- `BeautifyScreenshotModel.swift`: the queue, background reading of each screenshot's size and thumbnail, and the batch save. `BeautifyScreenshotView.swift`: the workspace; the checkerboard for Transparent is at the bottom of that file.
- Tests: `Tests/ToolboxTests/BeautifyScreenshotTests.swift` (canvas ratios, frame size, pixels kept, background and transparency, saved PNG and original untouched).

## Not done
- Window frame mockup (the brief's optional item).
- Output metadata: the PNG carries none of the screenshot's metadata.
