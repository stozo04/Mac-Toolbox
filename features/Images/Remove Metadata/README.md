# Remove Metadata

**Category:** Images  
**SF Symbol:** `location.slash`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Remove Metadata`)

Strip location, camera and date info from photos.

## Design reference
`images/Images/Remove Metadata.png`

## Current state
Built. `RemoveMetadataView` (queue + 240pt options panel) is routed from `ToolWorkspace` via `ToolInput.removeMetadata`. Drop photos or folders (each row lists what that photo carries: location, camera, dates, other details), leave Keep orientation on or off, click Remove Metadata. Clean copies keep their file names and go to a dated "Toolbox Clean Photos" folder in Downloads; each row then says what was removed and the panel says how many photos had details taken out.

- `MetadataStripper.swift` - the service. `scan` reads the ImageIO property groups ({GPS}, {Exif}, {TIFF}, {IPTC}, {PNG} text, Maker notes) and the XMP tags and sorts them into `MetadataKind`s; entries that only describe the picture (size, color space, orientation, compression) do not count.
- JPEG: `CGImageDestinationCopyImageSource` with empty metadata, so the picture data is copied untouched (no re-encode, no quality loss) and EXIF, IPTC, XMP, GPS and comments are gone. Only the rotation tag is written back when Keep orientation is on.
- PNG, TIFF, HEIC and others: ImageIO leaves details behind on a metadata-edit copy for these (verified), so the picture is decoded and saved again with nothing attached. PNG and TIFF come back pixel for pixel; HEIC is saved at 0.9 quality. WebP goes through the lossless WebP encoder, upright, with no tag. Animated images are refused.
- Keep orientation off: sideways photos are turned upright in the pixels (JPEG is re-encoded at 0.95 in that case) and no rotation tag is written.
- Verify pass: the saved copy is scanned again; if anything private is left (or the rotation tag is wrong) the copy is deleted and the row fails rather than hand over a file that looks clean but is not. The ICC color profile is kept; it describes color, not the photo.
- Not built: choosing which categories to strip (the design has only the Keep orientation toggle), a before/after metadata inspector.

## Implementation notes for an agent
- ImageIO copy without EXIF/GPS/TIFF dictionaries.
- Put the tool's logic in `Sources/Toolbox/Tools/Images/RemoveMetadata/` and swap `ToolWorkspace` for a dedicated view when the tool needs more than the generic empty state.
- Everything runs on device; never modify the original file (write a new output next to it or to a chosen folder).
- Match the screenshot: dark cards, `Theme` colors, options panel width 240, rounded `cardBackground`.
- Keep UI state in a per-tool `@Observable` model; keep processing in a separate service type so it is testable without UI.
