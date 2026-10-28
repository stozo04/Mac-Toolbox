# Blur Faces

**Category:** Images  
**SF Symbol:** `face.dashed`  
**Catalog entry:** `Sources/Toolbox/Models/ToolCatalog.swift` (id `Images/Blur Faces`)

Find faces in photos and blur, pixelate or black them out.

## Design reference
`images/Images/Blur Faces.png` (the catalog card; the workspace follows the screenshots in the request: empty state, Options with Style and Strength, face list in Options, before and after preview).

## Current state
Built (`Sources/Toolbox/Tools/Images/BlurFaces/`, routed through `ToolInput.blurFaces`). Queue of photos (files or folders). Each photo is checked for faces in the background as it is added; the status shows how many were found. The preview shows the selected photo Before and After at the current style and strength. "Blur Faces" writes a copy of every photo into a new "Toolbox Blurred Photos" folder in Downloads, same file name.

- Options: Style (Blur, Pixelate, Black Box), Strength (1 to 100; Black Box ignores it), and the faces in the selected photo, each with a switch to leave it visible.
- Each face is covered with a margin of 15% of its width and 20% of its height, so hair and chin edges are covered too.
- A photo with no faces left to hide is copied byte for byte, so its file is the same as the original.
- A photo that has faces hidden keeps its format (JPG, HEIC, PNG; others such as WebP are saved as PNG) and is turned upright. Camera, date and location details are kept, the same as Convert Images' "Keep metadata"; use Remove Metadata to strip them.
- Originals are never modified.

## Implementation
- `FaceBlur.swift`: `VNDetectFaceRectanglesRequest` finds faces on the full-size photo, passing its EXIF orientation. Core Image does the hiding: `CIGaussianBlur`, `CIPixellate` or a black rectangle, each clipped to the margin.
- `BlurFacesModel.swift`: the queue, background detection, and the batch save. `BlurFacesView.swift`: the workspace.
- Tests: `Tests/ToolboxTests/BlurFacesTests.swift` (copy of an unfaced photo, black box and blur regions, orientation and format on save, a plain photo has no faces).

## Not done
- Faces that Vision misses (very small, turned away or in profile) can't be hidden by hand; there is no draw-your-own box yet.
- Video frames are not handled.
