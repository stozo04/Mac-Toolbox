# Extract Frames

**Category:** Video  
**SF Symbol:** `photo.on.rectangle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Extract Frames`)

Save stills from videos as PNG, JPEG or HEIC images.

## Design reference
`images/Video/Extract Frames.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Video/ExtractFrames/`, routed through `ToolInput.extractFrames`.

- **Frames:** every N seconds, frames per second (1-30), a set number spread evenly, or Pick by hand (scrub a player, step frame by frame, Save Frame saves one image per click).
- **Only part of each video:** optional start/end (end blank = to the end).
- **Format:** PNG, JPEG or HEIC, with a quality slider for JPEG/HEIC.
- **Size:** Original, 1920, 1280, 640 or 320 px on the longest side; never enlarged.
- **Save as:** Images, Images + ZIP, or ZIP only (skips the preview; the images are made in a temp folder and zipped with `ditto`, no `__MACOSX` files).
- **Save to:** next to each video (default; Downloads if that folder is read-only) or a chosen folder. Each run makes a new `<name> Frames` folder (`<name> Frames 2` ...), so nothing is overwritten.
- Files are named `<name>_0001_00m05.250s.png` (index for order, then the time).
- Results: a grid of thumbnails filled in as frames are saved; double-click opens, drag out, right-click for Open / Show in Finder / Copy, eye button reveals.
- Extract Again re-runs every video with new options; failed videos can be retried.
- Timing follows the video track, not the file (sound can run past the last frame).
- Over 5000 frames from one video is refused with a message.

Debug-only launch flags for checking the filled-in screens: `--frames-files a.mp4,b.mov [--frames-mode manual] [--frames-run]`.

Tests: `Tests/ToolboxTests/ExtractFramesTests.swift`.

## Implementation notes for an agent
- AVAssetImageGenerator for stills; ImageIO for PNG/JPEG/HEIC encoding.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/ExtractFrames/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
