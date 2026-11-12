# AGENTS.md

Quick orientation for any coding agent working in this repo.

## What this is
Toolbox: a native macOS app (SwiftUI, macOS 14+, Swift Package Manager) that bundles many small utilities (video, audio, images, docs, text & speech, files, Mac) in one window. Everything is meant to run on device. The designs are screenshots in `images/` (`images/All.png` is the home screen).

**Current state:** navigation, catalog, theme (dark/light toggle), logging and generic empty-state workspaces exist. Thirty-seven tools are built: eleven in Images (Convert Images, `Sources/Toolbox/Tools/Images/ConvertImages/`, with the vendored WebP encoder in `Sources/CWebP/`; Compress Images, `Sources/Toolbox/Tools/Images/CompressImages/`, built on the Convert Images encoder; Blur Faces, `Sources/Toolbox/Tools/Images/BlurFaces/`, Vision face detection; Beautify Screenshot, `Sources/Toolbox/Tools/Images/BeautifyScreenshot/`; Resize Images, `Sources/Toolbox/Tools/Images/ResizeImages/`, by percentage, longest side or exact size, with a preview whose handles you drag to set the size; Rotate Images, `Sources/Toolbox/Tools/Images/RotateImages/`, 90 degree turns and flips for a whole batch with a live preview of the result; Remove Background, `Sources/Toolbox/Tools/Images/RemoveBackground/`; Remove Metadata, `Sources/Toolbox/Tools/Images/RemoveMetadata/`, lossless JPEG copy plus a verify pass; Redact Image, `Sources/Toolbox/Tools/Images/RedactImage/`, blur, pixelate or black box over regions you drag or Find & Cover finds with Vision; Annotate Screenshot, `Sources/Toolbox/Tools/Images/AnnotateScreenshot/`, one image at a time with arrows, shapes, text, numbered steps, pen, blur and crop, copy/save/drag-out, paste and Capture Area; Color Picker, `Sources/Toolbox/Tools/Images/ColorPicker/`, samples any pixel with `NSColorSampler` (no screen recording permission) and copies it as HEX, rgb(), hsl(), OKLCH, SwiftUI, NSColor, UIColor or the nearest Tailwind color, keeps the last 20 colors, finds 5 to 8 main colors of an image and checks a text/background pair against WCAG 2), two in Docs (Redact PDF, `Sources/Toolbox/Tools/Docs/RedactPDF/`: drag boxes or Find & Redact a word on every page, pages with boxes are flattened to images so the text under them is gone, the rest are copied, the document details are dropped, and the saved copy is checked before it is kept; Scan Document, `Sources/Toolbox/Tools/Docs/ScanDocument/`: Vision finds the page in a photo (the page-aware and rectangle detectors are compared), Core Image straightens it and cleans it up as Color, Grayscale or Black & White, pages are reordered/rotated/removed, and Save PDF writes one PDF with an optional invisible text layer from Vision OCR; Continuity Camera import is in `ContinuityCamera.swift`), ten in Video (Download Video, Record Screen, Trim Video, Video to GIF, Resize Video, Compress Video, Extract Frames, Media Info, Mute Video, Burn In Subtitles; code in `Sources/Toolbox/Tools/Video/`, each routed from `ToolWorkspace` through its own `ToolInput` case) and all fourteen in Mac (code in `Sources/Toolbox/Tools/Mac/<Tool>/`, routed through the single `ToolInput.mac(MacTool)` case and `MacToolView`; shared pieces are `Tools/Mac/MacUI.swift`, `Support/Shell.swift`, `Support/SystemDefaults.swift`, `Support/CodeSignInfo.swift`, `Support/DirectorySize.swift`). The **AI Models** page is real too (`Views/ModelsView.swift`, logic in `Sources/Toolbox/AIModels/`): it lists the models on this Mac with what each does (a folder of `.safetensors` shards beside a `config.json` or similar is one model), its location and the apps that use it, keeps itself current (FSEvents on the folders models live in, Spotlight for loose files, a look when the app comes forward), and can gather movable models into `~/Library/Application Support/Toolbox/AI Models`, leaving a symlink behind (checked against DigUp's own helper; models of other apps, the Hugging Face cache and Ollama are never moved). The **Vault** page is real (`Sources/Toolbox/Vault/`, brief in `features/Vault/README.md`): a password-protected, hidden library of photos and videos stored in an AES-256 encrypted disk image that Finder also only opens with the password; files are moved in (copied, checked, original deleted), and a viewer steps through them with the arrow keys. Smart search finds them by what they show or say, with EmbeddingGemma 2 on llama.cpp (`Sources/VaultSearch/`, adapted from DigUp), its index kept inside the vault. Every other tool still shows the generic empty state and does not process anything. Building a dedicated, design-accurate view per tool is the main remaining work. Network code exists only for Download Video, Network Speed Test (Apple's `networkQuality`), the Vault's one-time search model download and the `Log` sink.

## Run / build
Apple silicon only. Build llama.cpp once first (Vault search; needs CMake): `scripts/build-llama.sh`.
```
scripts/build-llama.sh
swift build
swift run Toolbox
.build/debug/Toolbox --page "Video/Trim Video"   # debug: open a page at launch (home | <Category> | <Category>/<Tool>)
.build/debug/Toolbox --release-notes             # debug: open the release history at launch
```

## Code map
- `Sources/Toolbox/Models/ToolCatalog.swift` - single source of truth for every tool (name, category, SF Symbol, tagline, workspace type). Add or rename tools here.
- `Sources/Toolbox/Models/Tool.swift`, `ToolCategory.swift` - models; `ToolInput` picks the generic workspace.
- `Sources/Toolbox/Support/ReleaseNotes.swift` - app version and release history; `Views/VersionBadge.swift` shows them.
- `Sources/Toolbox/Support/AppState.swift` - page, search, favorites, recents, dark/light. `Theme.swift` - adaptive colors (use `Theme.*`, never hardcode white/black).
- `Sources/Toolbox/AIModels/` - `ModelScanner` (where models are and what they are), `ModelKnowledge` (plain-words descriptions), `GGUFInfo`, `AppAssociations` (which app uses a model), `ModelLibrary` (the live list: `FileWatcher` + Spotlight), `ModelMover` (central folder with links).
- `Sources/Toolbox/Vault/` - `VaultDisk` (encrypted image via `diskutil image`), `VaultMover` (verified move in), `VaultLibrary`, `VaultThumbnails`, `VaultModel`, and the door, library and viewer views. `Vault/Search/` - `VaultSearchEngine`, `VaultIndex` (SQLite inside the vault), `VaultRanking`, `VaultModelDownload`, `VaultSearchBar`.
- `Sources/VaultSearch/` + `Sources/CLlama/` - EmbeddingGemma 2 on llama.cpp (`LlamaEmbedder`), media readers and scoring, adapted from DigUp (MIT). Not linted (kept close to DigUp's code).
- `Sources/Toolbox/Views/` - `RootView`, `TopBar`, `HomeView`, `CategoryView`/`ToolCard`, `ToolView` (shared header + `ToolWorkspace` switch), `Workspaces.swift` (DropZone, Link, Live, Text, OptionsPanel).
- `features/<Category>/<Tool>/README.md` - per-tool brief: design screenshot, sub-features, implementation notes.

## How to build a tool
1. Read the tool's README below and open the screenshot it names.
2. Create the view and logic under `Sources/Toolbox/Tools/<Category>/<Tool>/` (separate service type from UI state so it is testable).
3. Route to it from `ToolWorkspace` in `Views/ToolView.swift`.
4. Run the app and compare against the screenshot (window-only screenshot: `screencapture -l<windowID>`; do not capture the full screen).

## Versioning (every PR)
- The version lives in one place: `AppVersion.current` in `Sources/Toolbox/Support/ReleaseNotes.swift` (semantic versioning, `MAJOR.MINOR.PATCH`). `scripts/make-app.sh` reads it for Info.plist, and the app shows it in the bottom-right corner; clicking it opens the release history.
- Every PR bumps it: PATCH for bug fixes and small tweaks, MINOR for a new tool or feature (resets PATCH), MAJOR only when the user says so. One bump per PR, even with several commits; if main moved on, re-bump above main's version before merging.
- In the same PR add a `Release` at the TOP of `ReleaseNotes.all` with today's date and one plain-words line per change, tagged `.new`, `.improved`, `.fixed` or `.removed`. Write for the user, not the code ("Trim Video keeps the sound", not "fix AVAssetExportSession preset").
- CI enforces it: the "Version bumped" job in `.github/workflows/ci.yml` runs `scripts/check-version-bump.sh`, which fails if the version is not higher than main's or the notes are missing. Run it locally before opening a PR. `ReleaseNotesTests` checks the history is ordered and matches the current version.
- After the PR merges, tag main: `git tag vX.Y.Z && git push origin vX.Y.Z` (ask before pushing).

## Rules
- On device only; no network/API calls unless a tool's README says otherwise (Download Video, Network Speed Test, the Vault's search model download). The one app-wide exception is `Log` (see `Support/Logging/`), which may send warning+ events to Supabase (all Supabase SQL objects are prefixed `macToolKit_`, see supabase/migrations/). Only the installed app sends (debug builds, `swift run` and `.build/` runs never do; `TOOLBOX_LOG_REMOTE=1` forces it for pipeline tests). Warning/error/critical logs must be detailed enough to diagnose without the user: use `Log.details(error, file:, [context])` (error type/domain/code/description, underlying error, file name/extension/size); `Log` adds the current page and the last events automatically. File names and link paths are fine; never file contents, passwords, tokens, link query strings or the account name (scrubbed by `LogText`). Vault logs drop file names too (`VaultLog`). A weekday 10:00 scheduled task (`scripts/log-fixer/PROMPT.md`) reads new warning+ rows and opens a draft PR with fixes; when you add a failure path, log it with `Log.details`.
- Never modify original user files; write new output. The Mac tools are the deliberate exception: they change system state (Hidden Settings, Presentation Mode, Login Items, Fix "App Is Damaged", Reset Permissions, Uninstall App, Storage Explorer). They never use `sudo`, send removals to the Trash (only the Trash itself is deleted for good, after a confirmation), and ask before anything that weakens a macOS safety check. The Vault page is the other exception: moving a photo or video into the vault deletes the original for good, but only after the copy inside the vault matches it byte for byte and opens; deleting inside the vault is permanent, after a confirmation, except duplicates removed from the Duplicates view, which go to the Trash inside the encrypted vault volume.
- Icon button that shows a file in Finder: use `RevealButton` (an eye), never a magnifying glass, which reads as search.
- Match the screenshots: dark cards, rounded corners, options panel ~240pt.
- Known gaps: Docs has 13 of 22 tools identified (the design shows 87 total; the catalog has 68: Battery Health and Replace Audio were dropped on purpose). 13 tools lack a screenshot; their README says so.
- Unbuilt tools show a big red "Feature not implemented" banner (`NotImplementedBanner` in `Views/ToolView.swift`) and a red triangle on their card. `Tool.isImplemented` is derived from `ToolInput.isImplemented` in `Models/Tool.swift`: the generic placeholder cases (`.dropFiles`, `.live`, `.text`) are false, every dedicated case is true, so a tool loses the banner as soon as it gets its own `ToolInput` case. Keep a new placeholder case out of the `default` branch there.
- `features/Video/*.md` are the original one-line specs, kept for reference.

## Tool index


### Video ([overview](features/Video/README.md))

- [Burn In Subtitles](features/Video/Burn%20In%20Subtitles/README.md) - Add captions to a video from an SRT file or automatic transcription.
- [Change Speed](features/Video/Change%20Speed/README.md) - Speed up or slow down videos without chipmunk voices.
- [Compress Video](features/Video/Compress%20Video/README.md) - Shrink video files while keeping them looking great.
- [Convert Video](features/Video/Convert%20Video/README.md) - Change videos to MP4, MOV, WebM or M4V.
- [Crop & Rotate Video](features/Video/Crop%20%26%20Rotate%20Video/README.md) - Crop, rotate and flip a video.
- [Download Video](features/Video/Download%20Video/README.md) - Save videos from YouTube, X, TikTok and more.
- [Extract Frames](features/Video/Extract%20Frames/README.md) - Save stills from videos as PNG, JPEG or HEIC images.
- [Media Info](features/Video/Media%20Info/README.md) - See the codec, resolution, frame rate, bitrate and metadata of videos and audio.
- [Merge Videos](features/Video/Merge%20Videos/README.md) - Join several clips into one video, in the order you choose.
- [Mute Video](features/Video/Mute%20Video/README.md) - Remove the soundtrack from videos without re-encoding.
- [Record Screen](features/Video/Record%20Screen/README.md) - Record a display, a window or an area, with sound.
- [Resize Video](features/Video/Resize%20Video/README.md) - Change the dimensions of videos to an exact size.
- [Trim Video](features/Video/Trim%20Video/README.md) - Cut the start and end of a clip without re-encoding.
- [Video to GIF](features/Video/Video%20to%20GIF/README.md) - Turn a clip into an animated GIF.

### Audio ([overview](features/Audio/README.md))

- [Clean Up Audio](features/Audio/Clean%20Up%20Audio/README.md) - Reduce background noise and hum in voice recordings and videos.
- [Convert Audio](features/Audio/Convert%20Audio/README.md) - Change audio files to MP3, M4A, WAV, FLAC or AIFF.
- [Extract Audio](features/Audio/Extract%20Audio/README.md) - Save the soundtrack of a video as an audio file.
- [Record Audio](features/Audio/Record%20Audio/README.md) - Record your voice, then transcribe it on device.
- [Trim Audio](features/Audio/Trim%20Audio/README.md) - Cut a song or recording down to the part you want.

### Images ([overview](features/Images/README.md))

- [Annotate Screenshot](features/Images/Annotate%20Screenshot/README.md) - Add arrows, boxes, numbers and text to a screenshot.
- [Beautify Screenshot](features/Images/Beautify%20Screenshot/README.md) - Put screenshots on a soft background with padding, rounded corners and a shadow.
- [Blur Faces](features/Images/Blur%20Faces/README.md) - Find faces in photos and blur, pixelate or black them out.
- [Color Picker](features/Images/Color%20Picker/README.md) - Pick any color on screen and copy it as HEX, RGB, HSL or code.
- [Compress Images](features/Images/Compress%20Images/README.md) - Make photos smaller without visible loss in quality.
- [Convert Images](features/Images/Convert%20Images/README.md) - Save photos as HEIC, WebP, JPG, JPEG or PNG.
- [Redact Image](features/Images/Redact%20Image/README.md) - Hide names, faces and private details in an image.
- [Remove Background](features/Images/Remove%20Background/README.md) - Lift the subject out of photos and save it with a transparent or solid background.
- [Remove Metadata](features/Images/Remove%20Metadata/README.md) - Strip location, camera and date info from photos.
- [Resize Images](features/Images/Resize%20Images/README.md) - Scale photos by percentage, longest side or exact size.
- [Rotate Images](features/Images/Rotate%20Images/README.md) - Rotate or flip many photos at once.

### Docs ([overview](features/Docs/README.md))

- [Compress PDF](features/Docs/Compress%20PDF/README.md) - Make PDFs smaller by recompressing their images.
- [Delete Pages](features/Docs/Delete%20Pages/README.md) - Remove the pages you don't need from a PDF.
- [Extract Pages](features/Docs/Extract%20Pages/README.md) - Save selected pages as a new PDF.
- [Fill & Flatten Forms](features/Docs/Fill%20%26%20Flatten%20Forms/README.md) - Fill in PDF forms, add text where there are no fields, and flatten the answers so they print as-is.
- [Images to PDF](features/Docs/Images%20to%20PDF/README.md) - Turn photos and scans into a single PDF document.
- [Make PDF Searchable](features/Docs/Make%20PDF%20Searchable/README.md) - Add an invisible text layer to scanned PDFs so you can search, select and copy their text.
- [Merge PDFs](features/Docs/Merge%20PDFs/README.md) - Combine several PDFs and images into one document.
- [Organize PDF](features/Docs/Organize%20PDF/README.md) - Reorder, rotate and remove pages in a PDF.
- [PDF to Word](features/Docs/PDF%20to%20Word/README.md) - Turn PDFs into Word documents you can edit, with headings, lists and paragraphs.
- [Redact PDF](features/Docs/Redact%20PDF/README.md) - Black out names, numbers or whole areas so they're removed for good, not just covered up.
- [Scan Document](features/Docs/Scan%20Document/README.md) - Scan paper with your iPhone or from photos. Pages are found, straightened and cleaned up.
- [Sign PDF](features/Docs/Sign%20PDF/README.md) - Draw or type your signature and place it on a document.
- [Split PDF](features/Docs/Split%20PDF/README.md) - Break a PDF into single pages or page ranges.

### Text & Speech ([overview](features/Text%20%26%20Speech/README.md))

- [Ask a Document](features/Text%20%26%20Speech/Ask%20a%20Document/README.md) - Ask questions about a PDF or document and get answers with page references.
- [Capture Text](features/Text%20%26%20Speech/Capture%20Text/README.md) - Select any area of the screen and copy the text in it.
- [Extract Text](features/Text%20%26%20Speech/Extract%20Text/README.md) - Recognize text in images, screenshots and scanned PDFs.
- [Summarize](features/Text%20%26%20Speech/Summarize/README.md) - Summarize text and documents on device with Apple Intelligence.
- [Text to Speech](features/Text%20%26%20Speech/Text%20to%20Speech/README.md) - Turn text, documents and PDFs into natural speech, and save it as audio.
- [Transcribe](features/Text%20%26%20Speech/Transcribe/README.md) - Turn speech in audio and video into a timestamped transcript.
- [Translate](features/Text%20%26%20Speech/Translate/README.md) - Translate text, documents and subtitles on device, keeping their formatting and timing.

### Files ([overview](features/Files/README.md))

- [Batch Rename](features/Files/Batch%20Rename/README.md) - Rename many files at once with find and replace, numbering, dates or case changes.
- [Find Duplicates](features/Files/Find%20Duplicates/README.md) - Find identical files across folders and move the extras to the Trash.
- [QR Code](features/Files/QR%20Code/README.md) - Make QR codes for links, text and Wi-Fi, or read codes and barcodes from images.
- [Zip & Unzip](features/Files/Zip%20%26%20Unzip/README.md) - Open ZIP, RAR, 7z and TAR files, or make a ZIP, with a password if you like.

### Mac ([overview](features/Mac/README.md))

- [Clean Keyboard](features/Mac/Clean%20Keyboard/README.md) - Pause the keyboard for a minute so you can wipe the keys without typing gibberish.
- [Display Control](features/Mac/Display%20Control/README.md) - Change the brightness, contrast and volume of external monitors, right from your Mac.
- [Eject All Disks](features/Mac/Eject%20All%20Disks/README.md) - Safely eject every external drive, card and disk image at once before you unplug.
- [Fix App Is Damaged](features/Mac/Fix%20App%20Is%20Damaged/README.md) - Check who made an app that won't open, then clear the download quarantine so macOS lets it run.
- [Hidden Settings](features/Mac/Hidden%20Settings/README.md) - Switch on useful macOS settings that aren't in System Settings, like a faster Dock or hidden files.
- [Keep Awake](features/Mac/Keep%20Awake/README.md) - Stop your Mac from sleeping during downloads, renders or talks, for as long as you choose.
- [Login & Background Items](features/Mac/Login%20%26%20Background%20Items/README.md) - See what starts with your Mac and runs in the background, who made it, and turn off what you don't need.
- [Mouse Fixes](features/Mac/Mouse%20Fixes/README.md) - Scroll your mouse and trackpad in different directions, and make the mouse wheel faster.
- [Network Speed Test](features/Mac/Network%20Speed%20Test/README.md) - Measure download, upload and responsiveness with Apple's own network test.
- [Presentation Mode](features/Mac/Presentation%20Mode/README.md) - One switch before you share your screen: hide desktop icons, hide the Dock and stay awake.
- [Reset Permissions](features/Mac/Reset%20Permissions/README.md) - Unstick an app's Screen Recording, Microphone, Camera or other privacy access.
- [Storage Explorer](features/Mac/Storage%20Explorer/README.md) - See what's filling your disk, find the usual space hogs and clear them out safely.
- [Uninstall App](features/Mac/Uninstall%20App/README.md) - Remove an app together with the caches, preferences and data it leaves behind.
- [Wi-Fi Password & QR](features/Mac/Wi-Fi%20Password%20%26%20QR/README.md) - Show the password of a saved Wi-Fi network and make a QR code guests can scan to join.
