# Compress Video

**Category:** Video  
**SF Symbol:** `arrow.down.right.and.arrow.up.left`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Compress Video`)

Shrink video files while keeping them looking great.

## Design reference
`images/Video/Compress Video.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Video/CompressVideo/`, routed from `ToolWorkspace` through `ToolInput.compressVideo`.

- Drop videos or a whole folder (`BatchFiles.videos`), then Compress. Smaller copies go to a new "Toolbox Compressed Videos <date>" folder in Downloads, named "Clip (Compressed).mp4". Originals are never touched. The queue lives in `CompressVideoModel.shared`.
- Options (240pt panel, as in the design): Quality High / Balanced / Small, Format H.264 / HEVC, Maximum size Original / 1080p / 720p / 480p, Remove audio, Use hardware encoder.
- `VideoCompressor` reads with `AVAssetReader` and writes with `AVAssetWriter` (mp4, fast start), so the bitrate is set directly instead of through an export preset. `CompressSettings.swift` (`VideoCompressPlan`) holds the arithmetic and is unit tested.
  - Video bitrate = pixels x frame rate x bits per pixel (High 0.12, Balanced 0.07, Small 0.04 for H.264; HEVC x0.55; hardware encoder x1.2). Above 30 fps the extra frames count half. It is never more than 90% of the source bitrate, with a 100 kbit/s floor.
  - Maximum size caps the **shorter** side (so 720p means the same for a vertical phone video), never enlarges, and keeps sides even.
  - Pictures that are not resized are read as stored and keep the file's rotation flag; resized ones are re-rendered upright through a video composition. A rotation matrix with no translation (some tools write that) is moved back into view first.
  - HLG / PQ (HDR) sources are converted to standard BT.709 video, so they do not look washed out.
  - Audio is re-encoded as AAC, stereo at most (160 / 128 / 96 kbit/s). Remove audio drops the soundtrack.
  - "Use hardware encoder" off asks VideoToolbox for its software encoder (better quality per bit, much slower for HEVC); on is much faster and a bit larger. If the writer refuses that choice, a plain second try is made without it and without the file's metadata.
  - If the new file would not be smaller, it is deleted and the row says so ("Already well compressed").
  - Cancel stops the encode and removes the partial file. `Job` opens a `Gate` for each pump, because a cancelled `AVAssetWriter` never asks for more samples.
- Each row shows "12.4 MB -> 3.1 MB, -75%"; the footer shows the total saved.

## Not built
- Estimated size before compressing, and target-size presets (WhatsApp, Discord, Mail).
- HDR is always converted to SDR; there is no option to keep 10-bit HEVC.
- Only the first video track is used; the container is always MP4.

