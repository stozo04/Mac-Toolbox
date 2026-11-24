# Mac Toolbox

**One app for the small jobs on your Mac.** [mac-toolbox.vercel.app](https://mac-toolbox.vercel.app)

Mac Toolbox puts the small utilities you reach for every day into one free, open-source app: trim a video, compress photos, black out part of a PDF, keep your Mac awake. The tools run on your Mac, and your original files are never changed.

The app itself, its window and the commands below say **Toolbox**.

> **Status: early preview (version 0.15.0).** Thirty-seven tools are fully working: ten **Video**, two **Audio** (**Trim Audio** and **Extract Audio**), all eleven **Images** and all fourteen **Mac** tools. For PDFs, the **Docs** category opens [Folio](https://github.com/Forward-Future/folio), a free PDF app, and **Video** also offers [Scarlet](https://github.com/Forward-Future/scarlet), a free AI video editor. Two pages sit beside the tools: **AI Models**, which finds the AI models on your Mac, and the **Vault**, a password-protected place for private photos and videos. The other tools can be browsed and opened, but don't process anything yet; they are being built one by one. See [What works today](#what-works-today).

## What's inside

| Category | What it's for | Tools |
|---|---|---|
| **Video** | Record, trim, convert and shrink video | Scarlet (opens the Scarlet app), Download Video, Burn In Subtitles, Change Speed, Extract Frames, Convert Video, Record Screen, Compress Video, Resize Video, Crop & Rotate Video, Media Info, Trim Video, Merge Videos, Mute Video, Video to GIF |
| **Audio** | Record, clean up and convert audio | Clean Up Audio, Record Audio, Trim Audio, Extract Audio, Convert Audio |
| **Images** | Edit, convert and protect photos | Blur Faces, Beautify Screenshot, Remove Background, Convert Images, Compress Images, Resize Images, Rotate Images, Remove Metadata, Color Picker, Redact Image, Annotate Screenshot |
| **Docs** | Read, sign and edit PDFs | Folio (opens the Folio app) |
| **Text & Speech** | Transcribe, translate and summarize, privately | Transcribe, Summarize, Extract Text, Capture Text, Translate, Text to Speech, Ask a Document |
| **Files** | Rename in bulk and make QR codes | QR Code, Batch Rename, Find Duplicates, Zip & Unzip |
| **Mac** | Free up space and fix what's stuck | Network Speed Test, Storage Explorer, Wi-Fi Password & QR, Keep Awake, Uninstall App, Presentation Mode, Clean Keyboard, Eject All Disks, Login & Background Items, Fix "App Is Damaged", Reset Permissions, Hidden Settings, Display Control, Mouse Fixes |

## Privacy

- The tools do their work on your Mac. Your files stay there unless you use one of the features listed below.
- Originals stay untouched. Results are saved as new files. The exceptions say so up front: the Mac tools change Mac settings (anything they remove goes to the Trash), and the Vault moves files into itself.
- These use the internet: Download Video (the downloads, updating yt-dlp, and Send to Google, which copies finished downloads to your Google Drive folder), Network Speed Test, the Vault's one-time download of its search model, Media Info's Open in Maps, which hands a video's location to Apple Maps when you click it, and the Logs page's Create GitHub Issue, which opens a filled-in issue in your browser for you to check and submit.
- The app keeps its own log on your Mac (`~/Library/Application Support/Toolbox/logs.sqlite`, 90 days) and shows it on the **Logs** page. Nothing in it is sent anywhere. An entry can include file names, the address of a link without its query string, your macOS version and a random install ID. It never includes file contents, passwords, tokens or your account name, and Vault entries leave out file names too. Runs from the project folder keep a separate log (`logs-dev.sqlite`).

## Using the app

- **Find a tool:** click a category at the top, or type in **Search tools**. Search matches names and descriptions.
- **Open a tool:** click its card. Most tools ask you to **drop a file** onto the window or click **Choose File...**. Some, like Download Video, take a pasted link. Others, like Keep Awake, are switches you flip.
- **Favorites:** click the star next to a tool's name. Favorites appear on the home screen.
- **Recent:** the tools you used last show up as quick buttons on the home and category pages.
- **AI Models, Vault and Logs:** the pills at the top next to the categories. Logs lists everything the app recorded, filtered by time and severity, with a count of each severity for the chosen time. Archive a log to hide it from the list and the counts; it is kept, and **Show archived** brings it back.
- **What's new:** click the version number in the bottom-right corner to see the release history.
- **Light or dark:** click the sun/moon button at the top right. It switches the whole app. (It opens in dark mode each time for now.)
- **Go back:** use the arrow at the top left of a tool page.

## What works today

### Working tools

#### Video

| Tool | What it does |
|---|---|
| **Download Video** | Paste one or more links (YouTube, X, TikTok, Instagram, Vimeo and more) and save them to a dated folder in Downloads. Choose best quality, 1080p, 720p or audio only, and prefer H.264 so the files play everywhere. Needs the internet. |
| **Record Screen** | Record a whole display, a single window, or an area you drag out, with system audio, your microphone (mixed into one track), the pointer, and highlighted clicks. Saves H.264 MOV or MP4 at Native, 1440p, 1080p or 720p and 30 or 60 fps. A floating timer and Stop bar stays out of the recording. Files are saved to Downloads. |
| **Trim Video** | Drop a video, drag the start and end handles on a filmstrip timeline (or set them to the playhead, or type a time), preview the selection, and save a `(Trimmed)` copy to a dated folder in Downloads. The video is copied without re-encoding whenever the format allows, so quality doesn't change. |
| **Video to GIF** | Drop one or more videos (or a whole folder), choose 10, 15 or 24 fps and a width of 320, 480, 640 pixels or the original size, and decide whether the GIF loops forever. Optionally convert only a part of each video by setting a start time and duration. GIFs are saved to a dated folder in Downloads; videos are never enlarged. |
| **Resize Video** | Drop one or more videos (or a whole folder) and resize them to a preset (4K, 1440p, 1080p, 720p, 480p, Square, Vertical) or any custom width and height. With the aspect ratio kept, choose Fit within size, Add black bars or Crop to fill; turn it off to stretch. Saves H.264 or HEVC MP4 files to a dated folder in Downloads. Odd sizes are rounded down to even, as video encoders require. |
| **Compress Video** | Shrink videos with High, Balanced or Small quality, as H.264 or HEVC, with an optional maximum size that never enlarges. Rotated videos stay upright, and a copy that wouldn't come out smaller isn't kept. |
| **Extract Frames** | Save stills from one or more videos: every few seconds, a set number per second, a set number spread evenly, or one at a time from a scrubbable player. Choose PNG, JPEG or HEIC and a size, and get images, a ZIP or both, in a new "Frames" folder. |
| **Media Info** | See the codec, resolution, frame rate, bitrate and metadata of videos and audio. |
| **Mute Video** | Remove the soundtrack from videos without re-encoding. |
| **Burn In Subtitles** | Add captions to a video from an SRT file or automatic transcription. |

Download Video can also copy finished downloads to a Google Drive folder, and with **Add to Vault** ticked it first moves them into the Vault with Touch ID, makes them searchable, and locks the Vault again.

#### Audio

| Tool | What it does |
|---|---|
| **Trim Audio** | Drag handles on a waveform to keep the part you want, add a fade in or out and hear it before saving. Save in the same format (copied as is, or rewritten losslessly) or as MP3, M4A, WAV, FLAC or AIFF. |
| **Extract Audio** | Save the soundtrack of one or more videos as M4A, MP3, WAV or AIFF. AAC sound is copied without losing quality. |

#### Images

| Tool | What it does |
|---|---|
| **Convert Images** | Save photos as HEIC, WebP, JPG, JPEG or PNG. |
| **Compress Images** | Make photos smaller without visible loss in quality. |
| **Resize Images** | Scale photos by percentage, longest side or exact size, with a preview whose handles you drag to set the size. |
| **Rotate Images** | Turn photos 90 degrees or flip them, a whole batch at once, with a live preview. Copies go to a dated folder in Downloads. |
| **Blur Faces** | Find faces in photos and blur, pixelate or black them out. |
| **Remove Background** | Lift the subject out of photos and save it with a transparent or solid background. |
| **Remove Metadata** | Strip location, camera and date info from photos. JPEGs are copied without losing quality, and the result is checked. |
| **Redact Image** | Blur, pixelate or black out areas you drag, or let Find & Cover find names and faces for you. |
| **Annotate Screenshot** | Add arrows, shapes, text, numbered steps, pen marks and blur to a screenshot, crop it, then copy, save or drag it out. |
| **Beautify Screenshot** | Put screenshots on a soft background with padding, rounded corners and a shadow. |
| **Color Picker** | Pick any color on screen and copy it as HEX, rgb(), hsl(), OKLCH, SwiftUI, NSColor, UIColor or the nearest Tailwind color. Keeps your last 20 colors, finds the main colors of an image and checks text against its background for WCAG contrast. |

#### Folio and Scarlet

| Card | What it does |
|---|---|
| **Folio** (Docs) | Opens [Folio](https://github.com/Forward-Future/folio), a free, open-source PDF reader and editor. If it isn't installed, the card's page links to its download. Folio does not scan paper or redact PDFs, so Scan Document and Redact PDF are gone. |
| **Scarlet** (Video) | Opens [Scarlet](https://github.com/Forward-Future/scarlet), a free, open-source AI video editor driven by Claude Code or Codex. If it isn't installed, the card's page links to its download. |

#### Mac

| Tool | What it does |
|---|---|
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
| **Mouse Fixes** | Reverse, speed up or smooth out the mouse wheel without touching the trackpad. Needs Accessibility access and works while the app is open. |

### AI Models

Lists the AI models on your Mac in plain words: what each one does, where it is, how big it is and which apps use it. The list stays current while the page is open. It can gather movable models into one folder (`~/Library/Application Support/Toolbox/AI Models`) and leave a link behind so their apps keep working; models that belong to other apps, the Hugging Face cache and Ollama are never moved.

### Vault

A hidden, password-protected library for photos and videos. They are stored in an AES-256 encrypted disk image, so even Finder only opens it with the password. The app shows a vault door you unlock; inside you can:

- **Move files in** by dropping them or clicking Add. Each copy is checked against the original before the original is deleted.
- **Browse** all items, only images or only videos (sorted by length), and step through them in a viewer with the arrow keys.
- **Search by what they show or say**, on your Mac, with EmbeddingGemma. The search model (865 MB) is downloaded once.
- **Find duplicates**, exact or likely, and send the extras to the Vault's own Trash, where you can put them back.
- **See details and rename** files with ⌘I.

The Vault locks when you leave the page, lock the screen, sleep or quit. Ticking **Use Touch ID to add downloads** when you unlock lets Download Video open it with your fingerprint.

### Coming soon

These 18 tools can be browsed and opened, but show a "Feature not implemented" banner and don't process files yet.

- **Video:** Change Speed, Convert Video, Crop & Rotate Video, Merge Videos
- **Audio:** Clean Up Audio, Record Audio, Convert Audio
- **Text & Speech:** Transcribe, Summarize, Extract Text, Capture Text, Translate, Text to Speech, Ask a Document
- **Files:** QR Code, Batch Rename, Find Duplicates, Zip & Unzip

### The app itself

| Works now | Not built yet |
|---|---|
| Browsing all categories and tools | The 18 tools listed under [Coming soon](#coming-soon) |
| Search, favorites, recent tools | Saving your favorites and settings between launches |
| Light / dark mode switch | A global hotkey for Record Screen |
| 37 working tools: ten Video, two Audio, eleven Images and all fourteen Mac | |
| The AI Models page and the Vault | |
| Release history (click the version number) | |

## Requirements

- A Mac running **macOS 14 (Sonoma) or later**.
- An Apple silicon Mac (M1 or later).
- To run the preview, you need Apple's developer tools (Xcode or the Command Line Tools) and CMake.

## Running the preview

Open Terminal in the project folder and run:

```
scripts/build-llama.sh
swift run Toolbox
```

`scripts/build-llama.sh` builds llama.cpp, which the Vault's smart search runs on (it needs CMake, from Homebrew or `uv`, and takes a few minutes once). The first run takes a minute to build. To quit, press **⌘Q**. To open a page straight away, add `--page`, for example `swift run Toolbox --page "Video/Trim Video"` or `--page Vault`. A run from the project folder keeps its own test vault and never opens the one the installed app uses.

To build the packaged app (`Toolbox.app` with yt-dlp and ffmpeg inside), run `scripts/fetch-tools.sh` then `scripts/make-app.sh`. It also makes `dist/Toolbox.dmg`, the download a GitHub release publishes as `Toolbox-X.Y.Z-macOS-Apple-Silicon.dmg`.

## Permissions you may be asked for

macOS asks for permission the first time a tool needs it. Today that means **Screen Recording** for Record Screen, **Microphone** only if you turn on the microphone there, **Accessibility** for Clean Keyboard and Mouse Fixes, and **Touch ID** if you let Download Video open the Vault. Later tools will ask for more, such as Microphone (Record Audio). When you run with `swift run`, macOS lists your terminal app in these prompts rather than Toolbox. You can change these any time in System Settings > Privacy & Security, or use **Reset Permissions** inside Toolbox.

## Feedback and contributing

Spotted something that doesn't match what you expected? [Open an issue](https://github.com/stozo04/Mac-Toolbox/issues/new/choose) with the tool's name and what you did. Want a tool that isn't here? Ask in [Discussions](https://github.com/stozo04/Mac-Toolbox/discussions).

The tools under [Coming soon](#coming-soon) each have a written brief and are open for anyone to build. [CONTRIBUTING.md](CONTRIBUTING.md) explains how, and [AGENTS.md](AGENTS.md) has the code map and the rules.

## License

[MIT](LICENSE.md)
