# Toolbox

**Every tool, right on your Mac.**

Toolbox puts the small utilities you reach for every day into one app: convert a video, trim a recording, compress photos, sign a PDF, rename a pile of files, keep your Mac awake. Everything runs on your Mac, and your original files are never changed.

> **Status: early preview.** The app's layout, navigation and look are in place, and nineteen tools are fully working: five video tools (**Download Video**, **Record Screen**, **Trim Video**, **Video to GIF**, **Resize Video**) and all fourteen **Mac** tools. The rest can be browsed and opened, but don't process anything yet; they are being built one by one. See [What works today](#what-works-today).

## What's inside

| Category | What it's for | Tools |
|---|---|---|
| **Video** | Record, trim, convert and shrink video | Download Video, Burn In Subtitles, Change Speed, Extract Frames, Convert Video, Record Screen, Compress Video, Resize Video, Crop & Rotate Video, Media Info, Trim Video, Merge Videos, Mute Video, Video to GIF |
| **Audio** | Record, clean up and convert audio | Clean Up Audio, Record Audio, Trim Audio, Extract Audio, Convert Audio |
| **Images** | Edit, convert and protect photos | Blur Faces, Beautify Screenshot, Remove Background, Convert Images, Compress Images, Resize Images, Rotate Images, Remove Metadata, Color Picker, Redact Image, Annotate Screenshot |
| **Docs** | Scan, sign, convert and protect documents | Scan Document, Redact PDF, Fill & Flatten Forms, Make PDF Searchable, PDF to Word, Sign PDF, Merge PDFs, Split PDF, Organize PDF, Delete Pages, Extract Pages, Images to PDF, Compress PDF, and more on the way |
| **Text & Speech** | Transcribe, translate and summarize, privately | Transcribe, Summarize, Extract Text, Capture Text, Translate, Text to Speech, Ask a Document |
| **Files** | Rename in bulk and make QR codes | QR Code, Batch Rename, Find Duplicates, Zip & Unzip |
| **Mac** | Free up space and fix what's stuck | Network Speed Test, Storage Explorer, Wi-Fi Password & QR, Keep Awake, Uninstall App, Presentation Mode, Clean Keyboard, Eject All Disks, Login & Background Items, Fix "App Is Damaged", Reset Permissions, Hidden Settings, Display Control, Mouse Fixes |
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

### Working tools

| Tool | What it does |
|---|---|
| **Download Video** | Paste one or more links (YouTube, X, TikTok, Instagram, Vimeo and more) and save them to a dated folder in Downloads. Choose best quality, 1080p, 720p or audio only, and prefer H.264 so the files play everywhere. Needs the internet. |
| **Record Screen** | Record a whole display, a single window, or an area you drag out, with system audio, your microphone (mixed into one track), the pointer, and highlighted clicks. Saves H.264 MOV or MP4 at Native, 1440p, 1080p or 720p and 30 or 60 fps. A floating timer and Stop bar stays out of the recording. Files are saved to Downloads. |
| **Trim Video** | Drop a video, drag the start and end handles on a filmstrip timeline (or set them to the playhead, or type a time), preview the selection, and save a `(Trimmed)` copy to a dated folder in Downloads. The video is copied without re-encoding whenever the format allows, so quality doesn't change. |
| **Video to GIF** | Drop one or more videos (or a whole folder), choose 10, 15 or 24 fps and a width of 320, 480, 640 pixels or the original size, and decide whether the GIF loops forever. Optionally convert only a part of each video by setting a start time and duration. GIFs are saved to a dated folder in Downloads; videos are never enlarged. |
| **Resize Video** | Drop one or more videos (or a whole folder) and resize them to a preset (4K, 1440p, 1080p, 720p, 480p, Square, Vertical) or any custom width and height. With the aspect ratio kept, choose Fit within size, Add black bars or Crop to fill; turn it off to stretch. Saves H.264 or HEVC MP4 files to a dated folder in Downloads. Odd sizes are rounded down to even, as video encoders require. |
| **Network Speed Test** | Measure download, upload, responsiveness and latency with Apple's own `networkQuality` test, with a gauge, a plain-language verdict and a history to compare rooms or times. |
| **Storage Explorer** | See what's filling your disk: the usual space hogs (app caches, Homebrew, Docker, simulators, backups, Trash, old Downloads) and a folder-size browser. Clearing goes to the Trash. |
| **Wi-Fi Password & QR** | Show the password of a saved Wi-Fi network (macOS asks for your approval) and make a QR code guests can scan to join. |
| **Keep Awake** | Stop your Mac sleeping for 30 minutes to 12 hours or until you stop it; optionally let the screen sleep, or only stay awake on the power adapter. |
| **Uninstall App** | Remove an app together with the caches, preferences and data it leaves behind, after you review them. Everything goes to the Trash. |
| **Presentation Mode** | One switch to hide desktop icons, hide the Dock and stay awake, then put everything back as it was. |
| **Clean Keyboard** | Pause the keyboard for 30 seconds to 2 minutes while the screen dims, so you can wipe the keys. Needs Accessibility access. |
| **Eject All Disks** | Eject every external drive, card and disk image at once. Network shares and the startup disk are never touched. |
| **Login & Background Items** | See what starts with your Mac and runs in the background, who made it and whether it's signed, and switch off your own items. |
| **Fix "App Is Damaged"** | Check who made an app macOS won't open, then clear its download quarantine (with a confirmation). |
| **Reset Permissions** | Unstick an app's Screen Recording, Microphone, Camera and other privacy permissions. |
| **Hidden Settings** | Dock delay and animation, hidden files, path bar, screenshot format and location, and more, with a reset arrow for each. |
| **Display Control** | Change an external monitor's brightness, contrast and volume over DDC/CI. Apple silicon only; some adapters and docks block it. |
| **Mouse Fixes** | Reverse, speed up or smooth out the mouse wheel without touching the trackpad. Needs Accessibility access and works while Toolbox is open. |

### The app itself

| Works now | Not built yet |
|---|---|
| Browsing all categories and tools | The other 54 tools: they open to an empty page and don't process files yet |
| Search, favorites, recent tools | Saving your favorites and settings between launches |
| Light / dark mode switch | The remaining Docs and Developer tools |
| Five video tools and all 14 Mac tools | A global hotkey for Record Screen |

## Requirements

- A Mac running **macOS 14 (Sonoma) or later**.
- To run the preview, you need Apple's developer tools (Xcode or the Command Line Tools).

## Running the preview

Open Terminal in the project folder and run:

```
swift run Toolbox
```

The first run takes a minute to build. To quit, press **⌘Q**. To open a tool straight away, add `--page`, for example `swift run Toolbox --page "Video/Trim Video"`.

To build the packaged app (a universal `Toolbox.app` with yt-dlp and ffmpeg inside), run `scripts/fetch-tools.sh` then `scripts/make-app.sh`.

## Permissions you may be asked for

macOS asks for permission the first time a tool needs it. Today that means **Screen Recording** for Record Screen, and **Microphone** only if you turn on the microphone there. Later tools will ask for more, such as Microphone (Record Audio) or Accessibility (Clean Keyboard). When you run with `swift run`, macOS lists your terminal app in these prompts rather than Toolbox. You can change these any time in System Settings > Privacy & Security, or use **Reset Permissions** inside Toolbox.

## Feedback

Spotted something that doesn't match what you expected? Note the tool name and what you did, and pass it along.

---

Building or contributing? Start with [AGENTS.md](AGENTS.md).
