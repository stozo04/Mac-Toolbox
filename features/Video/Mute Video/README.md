# Mute Video

**Category:** Video  
**SF Symbol:** `speaker.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Video/Mute Video`)

Remove the soundtrack from videos without re-encoding.

## Design reference
`images/Video/Mute Video.png`

## Current state
Built (`Sources/Toolbox/Tools/Video/MuteVideo/`, routed through `ToolInput.muteVideo`). Queue of videos (files or folders), "Mute" saves `<name> (Muted).<ext>` into a new "Toolbox Muted Videos" folder in Downloads. `VideoMuter` copies only the video tracks (turn and metadata kept) with the passthrough preset in the original container (MP4, M4V, otherwise MOV); if passthrough is refused it re-encodes at highest quality and the row says "re-encoded". Each finished row shows duration, new size and size saved; the footer totals the savings. Videos with no sound are reported and nothing is written. The shared export runner is `Support/AssetExporter.swift`.

## Sub-features / options to build
- Batch
- Show duration and size saved

## Implementation notes for an agent
- Export with the audio tracks omitted via passthrough; no re-encode.
- Put the tool's logic in `Sources/Toolbox/Tools/Video/MuteVideo/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
