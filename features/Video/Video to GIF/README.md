# Video to GIF

**Category:** Video  
**SF Symbol:** `livephoto`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Video to GIF`)

Turn a clip into an animated GIF.

## Design reference
`images/Video/Video To Gif.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Video/VideoToGIF/`:
- `VideoToGifView` / `VideoToGifModel` - UI and state (shared model, so the queue survives switching tools): drop zone (files or folders), a queue with per-file progress and size, and the 240pt options panel (frame rate 10/15/24, width 320/480/640/Original, loop forever, convert only part with start and duration).
- `GifConverter` - `AVAssetImageGenerator` frames written with ImageIO `CGImageDestination`. Output is `<name>.gif` in a dated `Toolbox GIFs ...` folder in Downloads; name clashes get a number suffix.
- `GifSettings` / `GifPlan` - pure logic: frame times, per-frame delays (running-total rounding so speed stays exact), never-enlarge sizing, range clamping, and the 3000-frame limit.

Tests: `Tests/ToolboxTests/VideoToGifTests.swift` (includes a real conversion of a generated video).

Not built: quality setting and size estimate (ImageIO's own quantization is used).

## Implementation notes for an agent
- AVAssetImageGenerator frames -> ImageIO `CGImageDestination` GIF; optional gifski-style quantization (not done).
- Put the tool's logic in `Sources/Toolbox/Tools/Video/VideotoGIF/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
