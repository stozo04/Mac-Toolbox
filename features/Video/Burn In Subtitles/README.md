# Burn In Subtitles

**Category:** Video  
**SF Symbol:** `captions.bubble`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Burn In Subtitles`)

Add captions to a video from an SRT file or automatic transcription.

## Design reference
`images/Video/Burn In Subtitles.png`

## Current state
Built (`Sources/Toolbox/Tools/Video/BurnInSubtitles/`, routed through `ToolInput.burnInSubtitles`). Queue of videos with batch options: Subtitles = Subtitle File (SRT or WebVTT; a file named like the video next to it is picked up automatically, otherwise the one chosen with "Choose...") or Transcribe Automatically (language picker limited to on-device languages, "Also save SRT"). Style: Size (Small/Medium/Large, a share of the video height), Position (Bottom/Top), Look (White with Shadow / White on Black Box), with a live sample drawn by the same `CaptionRenderer` as the export. "Burn In" saves `<name> (Subtitled).<ext>` into a new "Toolbox Subtitled Videos" folder in Downloads.

How it works: `SubtitleFile` parses SRT/VTT (BOM, CRLF, UTF-16/Latin-1, markup stripped); `CaptionRenderer` draws each caption to an image at the video's resolution; `SubtitleBurner` puts one layer per caption in an `AVVideoCompositionCoreAnimationTool` (opacity switched on/off with a discrete keyframe animation) and exports with the highest-quality preset, so the picture is re-encoded (audio, turn and metadata are kept). Auto mode uses `Support/SpeechTranscriber.swift` (`SFSpeechRecognizer`, on-device only) and `CueBuilder` to group words into captions; the engine is meant to be reused by Transcribe.

Needs `NSSpeechRecognitionUsageDescription`, which `scripts/make-app.sh` now writes: automatic mode only works in the packaged app (from `swift run` it says so instead of crashing). Not verified end to end: the permission prompt and a real transcription have not been run. Memory: every caption is a bitmap held until the export ends, so a very long video with thousands of captions needs a lot of RAM.

## Sub-features / options to build
- Source: SRT file or automatic transcription
- Style: font, size, color, background, position
- Preview before export

## Implementation notes for an agent
- AVFoundation composition + Core Animation text layers, or ffmpeg `subtitles` filter. Auto mode reuses the Transcribe engine (Speech framework).
- Put the tool's logic in `Sources/Toolbox/Tools/Video/BurnInSubtitles/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
