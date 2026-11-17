# Extract Audio

**Category:** Audio  
**SF Symbol:** `film.stack`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Audio/Extract Audio`)

Save the soundtrack of a video as an audio file.

## Design reference
`images/Audio/Extract Audio.png`

## Current state
Built. Code in `Sources/Toolbox/Tools/Audio/ExtractAudio/`, routed through `ToolInput.extractAudio`.

- Drop videos or whole folders; they queue up like Mute Video, each row showing progress, then format, length, size and whether the sound was copied as is, with a reveal button.
- Options (apply to the whole batch): **Format** M4A (AAC), MP3, WAV or AIFF; **Bitrate** 128, 192, 256 or 320 kbps for M4A and MP3 (WAV and AIFF are uncompressed).
- Output goes to a new dated "Toolbox Extracted Audio" folder in Downloads, named after the video ("Clip.m4a", "Clip 2.m4a" on a clash). Originals are never touched.
- A video with no sound is reported as such and nothing is written.

## How it works
- The first audio track is used. Mono stays mono; anything above stereo is mixed down to stereo.
- **M4A from AAC** (incl. HE-AAC): copied packet for packet with the bundled ffmpeg (`-c:a copy -f ipod`), so the file decodes to exactly the original samples and the chosen bitrate is ignored. Without ffmpeg, an AVAssetReader/Writer passthrough is used; it can drop pre-roll packets that are timed before zero.
- **M4A from other sound**: AVAssetReader decodes to PCM, AVAssetWriter encodes AAC at the chosen bitrate (44.1 or 48 kHz; mono is capped at 256 kbps).
- **WAV / AIFF**: 16-bit PCM at the video's own sample rate (AIFF big-endian), written by AVAssetWriter.
- **MP3**: ffmpeg with LAME (`libmp3lame`), at the chosen bitrate; sample rates above 48 kHz are lowered to 48 kHz. LAME is built from source and linked statically into the bundled ffmpeg by `scripts/fetch-tools.sh`.
- Sample rate and channels come from the richest decodable format, so HE-AAC (whose base layer reports half the rate and one channel) comes out at its real rate and channel count.
- Progress for ffmpeg runs comes from `-progress pipe:1` (`FFmpegProgress`).

## Tests
`Tests/ToolboxTests/ExtractAudioTests.swift`. The MP3 and lossless-copy tests use `build/tools/ffmpeg` (run `scripts/fetch-tools.sh`) or Homebrew's.
