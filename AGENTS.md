# AGENTS.md

Quick orientation for any coding agent working in this repo.

## What this is
Toolbox: a native macOS app (SwiftUI, macOS 14+, Swift Package Manager) that bundles many small utilities (video, audio, images, docs, text & speech, files, Mac, developer) in one window. Everything is meant to run on device. The designs are screenshots in `images/` (`images/All.png` is the home screen).

**Current state: skeleton only.** Navigation, catalog, theme (dark/light toggle) and generic empty-state workspaces exist. No tool actually processes anything, and there is no API or network code. Most tool pages do not yet match their screenshot; building a dedicated, design-accurate view per tool is the main remaining work.

## Run / build
```
swift build
swift run Toolbox
.build/debug/Toolbox --page "Video/Trim Video"   # debug: open a page at launch (home | <Category> | <Category>/<Tool>)
```

## Code map
- `Sources/Toolbox/Models/ToolCatalog.swift` - single source of truth for every tool (name, category, SF Symbol, tagline, workspace type). Add or rename tools here.
- `Sources/Toolbox/Models/Tool.swift`, `ToolCategory.swift` - models; `ToolInput` picks the generic workspace.
- `Sources/Toolbox/Support/AppState.swift` - page, search, favorites, recents, dark/light. `Theme.swift` - adaptive colors (use `Theme.*`, never hardcode white/black).
- `Sources/Toolbox/Views/` - `RootView`, `TopBar`, `HomeView`, `CategoryView`/`ToolCard`, `ToolView` (shared header + `ToolWorkspace` switch), `Workspaces.swift` (DropZone, Link, Live, Text, OptionsPanel).
- `features/<Category>/<Tool>/README.md` - per-tool brief: design screenshot, sub-features, implementation notes.

## How to build a tool
1. Read the tool's README below and open the screenshot it names.
2. Create the view and logic under `Sources/Toolbox/Tools/<Category>/<Tool>/` (separate service type from UI state so it is testable).
3. Route to it from `ToolWorkspace` in `Views/ToolView.swift`.
4. Run the app and compare against the screenshot (window-only screenshot: `screencapture -l<windowID>`; do not capture the full screen).

## Rules
- On device only; no network/API calls unless a tool's README says otherwise (Download Video, Network Speed Test).
- Never modify original user files; write new output.
- Match the screenshots: dark cards, rounded corners, options panel ~240pt.
- Known gaps: Docs has 13 of 22 tools identified, Developer 4 of 8 (the design shows 87 total; the catalog has 74). 17 tools lack a screenshot; their README says so.
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
- [Replace Audio](features/Video/Replace%20Audio/README.md) - Swap or add the soundtrack of a video with another audio file.
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
- [Convert Images](features/Images/Convert%20Images/README.md) - Save photos as JPEG, PNG, HEIC, TIFF or WebP.
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

- [Battery Health](features/Mac/Battery%20Health/README.md) - See your Mac's battery capacity, cycle count and charger, plus AirPods and accessory levels.
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

### Developer ([overview](features/Developer/README.md))

- [Base64](features/Developer/Base64/README.md) - Encode and decode Base64.
- [Diff Checker](features/Developer/Diff%20Checker/README.md) - Compare two blocks of text and see what changed.
- [Hash Generator](features/Developer/Hash%20Generator/README.md) - Create MD5, SHA-1 and SHA-256 hashes of text or files.
- [JSON Formatter](features/Developer/JSON%20Formatter/README.md) - Format, validate and minify JSON.
