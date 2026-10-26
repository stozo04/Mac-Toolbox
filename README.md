# Toolbox

**Every tool, right on your Mac.**

Toolbox puts the small utilities you reach for every day into one app: convert a video, trim a recording, compress photos, sign a PDF, rename a pile of files, keep your Mac awake. Everything runs on your Mac, and your original files are never changed.

> **Status: early preview.** The app's layout, navigation and look are in place, but the tools themselves don't do their jobs yet. You can browse every tool and open its page; processing is being built tool by tool. See [What works today](#what-works-today).

## What's inside

| Category | What it's for | Tools |
|---|---|---|
| **Video** | Record, trim, convert and shrink video | Download Video, Burn In Subtitles, Change Speed, Extract Frames, Convert Video, Record Screen, Compress Video, Resize Video, Crop & Rotate Video, Media Info, Trim Video, Merge Videos, Mute Video, Replace Audio, Video to GIF |
| **Audio** | Record, clean up and convert audio | Clean Up Audio, Record Audio, Trim Audio, Extract Audio, Convert Audio |
| **Images** | Edit, convert and protect photos | Blur Faces, Beautify Screenshot, Remove Background, Convert Images, Compress Images, Resize Images, Rotate Images, Remove Metadata, Color Picker, Redact Image, Annotate Screenshot |
| **Docs** | Scan, sign, convert and protect documents | Scan Document, Redact PDF, Fill & Flatten Forms, Make PDF Searchable, PDF to Word, Sign PDF, Merge PDFs, Split PDF, Organize PDF, Delete Pages, Extract Pages, Images to PDF, Compress PDF, and more on the way |
| **Text & Speech** | Transcribe, translate and summarize, privately | Transcribe, Summarize, Extract Text, Capture Text, Translate, Text to Speech, Ask a Document |
| **Files** | Rename in bulk and make QR codes | QR Code, Batch Rename, Find Duplicates, Zip & Unzip |
| **Mac** | Free up space and fix what's stuck | Network Speed Test, Storage Explorer, Wi-Fi Password & QR, Battery Health, Keep Awake, Uninstall App, Presentation Mode, Clean Keyboard, Eject All Disks, Login & Background Items, Fix "App Is Damaged", Reset Permissions, Hidden Settings, Display Control, Mouse Fixes |
| **Developer** | Format, decode, hash and compare | Hash Generator, Diff Checker, Base64, JSON Formatter, and more on the way |

## Privacy

- Tools are designed to work on your Mac, with nothing uploaded.
- Originals stay untouched. Results are saved as new files.
- The only tools that need the internet are the ones that are about it by nature, such as Download Video and Network Speed Test.

## Using the app

- **Find a tool:** click a category at the top, or type in **Search tools**. Search matches names and descriptions.
- **Open a tool:** click its card. Most tools ask you to **drop a file** onto the window or click **Choose File...**. Some, like Download Video, take a pasted link. Others, like Keep Awake, are switches you flip.
- **Favorites:** click the star next to a tool's name. Favorites appear on the home screen.
- **Recent:** the tools you used last show up as quick buttons on the home and category pages.
- **Light or dark:** click the sun/moon button at the top right. It switches the whole app. (It opens in dark mode each time for now.)
- **Go back:** use the arrow at the top left of a tool page.

## What works today

| Works now | Not built yet |
|---|---|
| Browsing all categories and tools | Actually processing files (converting, trimming, compressing...) |
| Search, favorites, recent tools | Most tool-specific controls and previews |
| Light / dark mode switch | Saving your favorites and settings between launches |
| Opening a tool page, choosing or dropping a file | The remaining Docs and Developer tools |

## Requirements

- A Mac running **macOS 14 (Sonoma) or later**.
- To run the preview, you need Apple's developer tools (Xcode or the Command Line Tools).

## Running the preview

Open Terminal in the project folder and run:

```
swift run Toolbox
```

The first run takes a minute to build. To quit, press **⌘Q**.

## Permissions you may be asked for

Once tools are working, macOS will ask for permission the first time a tool needs it, such as Screen Recording (Record Screen), Microphone (Record Audio), or Accessibility (Clean Keyboard). You can change these any time in System Settings > Privacy & Security, or use **Reset Permissions** inside Toolbox.

## Feedback

Spotted something that doesn't match what you expected? Note the tool name and what you did, and pass it along.

---

Building or contributing? Start with [AGENTS.md](AGENTS.md).
