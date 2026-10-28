# Remove Background

**Category:** Images  
**SF Symbol:** `person.crop.rectangle`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Remove Background`)

Lift the subject out of photos and save it with a transparent or solid background.

## Design reference
`images/Images/Remove Background.png`

## Current state
Built (`Sources/Toolbox/Tools/Images/RemoveBackground/`, routed through `ToolInput.removeBackground`). Queue of photos (files or folders), each with a thumbnail. The preview shows the selected photo Before and After at the current background. "Remove Background" writes a PNG of every waiting photo into a new "Toolbox Cutouts" folder in Downloads, same file name.

- Options: Background (Transparent, White, Color with a color well) and Crop to subject (trims the cutout to the subject's bounding box).
- Results are always PNG so transparent areas are kept. The copy has no metadata.
- A photo with no subject is reported as "No subject was found in this photo." and the batch moves on.
- Originals are never modified.

## Implementation
- `RemoveBackground.swift`: `VNGenerateForegroundInstanceMaskRequest` finds the subject on the upright photo and returns a grayscale mask (white is the subject). `CIBlendWithMask` puts the photo over a clear, white or solid background. Crop to subject reads the mask's bounds.
- `RemoveBackgroundModel.swift`: the queue and the batch save. `RemoveBackgroundView.swift`: the workspace.
- Tests: `Tests/ToolboxTests/RemoveBackgroundTests.swift` (transparent, white and color compositing, bounds measured from the top left, crop, unreadable file). The Vision step is only checked by hand on sample photos.

## Not done
- Refine / edge feather: the mask is used as Vision returns it, with no feathering or manual brush.
- Vision can include parts that are not the subject (a glow or a shadow close to it) and can miss a subject it does not recognize; there is no touch-up step yet.

## Help copy
How to use Remove Background

1. Open Remove Background and drop your photos.
2. Choose Transparent, White or a custom Color background.
3. Turn on Crop to subject if you want the image trimmed to the cutout.
4. Click Remove Background. PNGs are saved to a dated folder in Downloads.

Questions about Remove Background

- **How do I remove the background from a picture on Mac?** Drop the picture into Remove Background in Toolbox and click Remove Background. You get a PNG of the subject with a transparent background, or white or a color if you choose.
- **Does it work without an internet connection?** Yes. The cutout is made with Apple's Vision framework on your Mac, so it works offline and the photo stays on your computer.
- **Why are the results saved as PNG?** PNG keeps transparent areas. JPEG has no transparency, so a cutout saved as JPEG would get a filled background.
- **What happens if no subject is found?** Toolbox reports that no subject was found in that photo and moves on to the rest of the batch.
