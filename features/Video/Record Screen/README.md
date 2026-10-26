# Record Screen

**Category:** Video  
**SF Symbol:** `record.circle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Record Screen`)

Record a display, a window or an area, with sound.

## Design reference
`images/Video/Record Screen.png`

## Current state
Built. Code is in `Sources/Toolbox/Tools/Video/RecordScreen/`:
- `RecordScreenView` / `RecordScreenModel` - UI and state (shared model, so a recording survives switching tools).
- `ScreenRecorder` - SCStream + AVAssetWriter (H.264, AAC), system audio from SCStream, microphone from AVCaptureSession, one serial queue.
- `AudioMixer` - mixes system audio and microphone into one stereo track. `RecordingOptions` - settings, output size and bitrate maths.
- `ClickHighlighter` - paints click rings into frames, so it also works for window capture.
- `AreaSelector` (drag overlay), `RecordingControlPanel` (floating timer + Stop, hidden from capture), `CaptureSources` (displays, windows, thumbnails).

Saved to Downloads as `Toolbox Screen Recording <date>.mov|mp4`. Needs Screen Recording permission; Microphone permission only when that toggle is on. The packaged app needs `NSMicrophoneUsageDescription` and the audio-input entitlement (`scripts/app.entitlements`).

Not built: global hotkey.

## Implementation notes for an agent
- ScreenCaptureKit (SCStream) + AVAssetWriter; needs Screen Recording and optionally Microphone permission.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/RecordScreen/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
