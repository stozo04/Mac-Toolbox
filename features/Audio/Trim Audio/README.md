# Trim Audio

**Category:** Audio  
**SF Symbol:** `scissors`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Audio/Trim Audio`)

Cut a song or recording down to the part you want.

## Design reference
`images/Audio/Trim Audio.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Audio/TrimAudio/`, routed through `ToolInput.trimAudio`.
- One audio file at a time (anything AVFoundation can read: MP3, M4A/AAC, WAV, FLAC, AIFF, CAF...). Its waveform is drawn from 400 peaks read on device (`AudioWaveform`).
- Drag the handles on the waveform, click to move the playhead, type a start or end time, or set either to the playhead. Space plays; Play Selection plays only the part that will be kept.
- Fade in and fade out (Off to 10 s), drawn on the waveform and heard while playing (an `AVAudioMix` volume ramp). Fades never run past the selection.
- Save As: Same as Original, MP3 (320 kbps), M4A (AAC 256 kbps), WAV, FLAC or AIFF. Saved by the bundled ffmpeg (`AudioTrimmer`) into a dated "Toolbox Trimmed Audio" folder in Downloads as "<name> (Trimmed).<ext>".
- Same as Original with no fades keeps the sound exactly: compressed files (MP3, AAC...) are copied packet for packet; WAV, AIFF and FLAC are rewritten losslessly at the same bit depth so the cut lands on the exact sample.

## Implementation notes for an agent
- `TrimAudioPlan` decides copy versus encode; `AudioTrimmer.arguments` builds the ffmpeg call (input seek, first soundtrack only, `afade` filters). Both are covered by `TrimAudioTests`.
- Put the tool's logic in `Sources/Toolbox/Tools/Audio/TrimAudio/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
