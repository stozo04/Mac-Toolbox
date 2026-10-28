import Foundation

enum ToolCatalog {
    static let all: [Tool] = video + audio + images + docs + textAndSpeech + files + mac + developer

    static func tools(in category: ToolCategory) -> [Tool] {
        all.filter { $0.category == category }
    }

    static func tool(id: String) -> Tool? {
        all.first { $0.id == id }
    }

    private static func drop(_ what: String, _ hint: String, _ symbol: String) -> ToolInput {
        .dropFiles(title: "Drop \(what) Here", hint: hint, symbol: symbol)
    }

    // MARK: Video

    static let video: [Tool] = [
        Tool(name: "Download Video", category: .video, symbol: "arrow.down.to.line",
             tagline: "Save videos from YouTube, X, TikTok and more.", input: .link),
        Tool(name: "Burn In Subtitles", category: .video, symbol: "captions.bubble",
             tagline: "Add captions to a video from an SRT file or automatic transcription.",
             input: .burnInSubtitles),
        Tool(name: "Change Speed", category: .video, symbol: "speedometer",
             tagline: "Speed up or slow down videos without chipmunk voices.",
             input: drop("a Video", "Drop a video to change its speed.", "film")),
        Tool(name: "Extract Frames", category: .video, symbol: "photo.on.rectangle",
             tagline: "Save stills from videos as PNG, JPEG or HEIC images.",
             input: drop("a Video", "Drop a video to pull frames from.", "film")),
        Tool(name: "Convert Video", category: .video, symbol: "arrow.triangle.2.circlepath",
             tagline: "Change videos to MP4, MOV, WebM or M4V.",
             input: drop("Videos", "Drop videos to convert.", "film")),
        Tool(name: "Record Screen", category: .video, symbol: "record.circle",
             tagline: "Record a display, a window or an area, with sound.",
             input: .recordScreen),
        Tool(name: "Compress Video", category: .video, symbol: "arrow.down.right.and.arrow.up.left",
             tagline: "Shrink video files while keeping them looking great.",
             input: drop("Videos", "Drop videos to shrink.", "film")),
        Tool(name: "Resize Video", category: .video, symbol: "arrow.up.left.and.arrow.down.right",
             tagline: "Change the dimensions of videos to an exact size.",
             input: .resizeVideo),
        Tool(name: "Crop & Rotate Video", category: .video, symbol: "crop.rotate",
             tagline: "Crop, rotate and flip a video.",
             input: drop("a Video", "Drop a video to crop or rotate.", "film")),
        Tool(name: "Media Info", category: .video, symbol: "info.circle",
             tagline: "See the codec, resolution, frame rate, bitrate and metadata of videos and audio.",
             input: .mediaInfo),
        Tool(name: "Trim Video", category: .video, symbol: "scissors",
             tagline: "Cut the start and end of a clip without re-encoding.",
             input: .trimVideo),
        Tool(name: "Merge Videos", category: .video, symbol: "rectangle.stack.badge.plus",
             tagline: "Join several clips into one video, in the order you choose.",
             input: drop("Videos", "Drop several clips to join.", "film")),
        Tool(name: "Mute Video", category: .video, symbol: "speaker.slash",
             tagline: "Remove the soundtrack from videos without re-encoding.",
             input: .muteVideo),
        Tool(name: "Video to GIF", category: .video, symbol: "livephoto",
             tagline: "Turn a clip into an animated GIF.",
             input: .videoToGif),
    ]

    // MARK: Audio

    static let audio: [Tool] = [
        Tool(name: "Clean Up Audio", category: .audio, symbol: "waveform.badge.magnifyingglass",
             tagline: "Reduce background noise and hum in voice recordings and videos.",
             input: drop("Audio", "Drop an audio or video file to clean up.", "waveform")),
        Tool(name: "Record Audio", category: .audio, symbol: "mic",
             tagline: "Record your voice, then transcribe it on device.",
             input: .live(symbol: "mic", idle: "Ready to record.", action: "Start Recording")),
        Tool(name: "Trim Audio", category: .audio, symbol: "scissors",
             tagline: "Cut a song or recording down to the part you want.",
             input: drop("Audio", "Drop audio to choose the part you want to keep.", "waveform")),
        Tool(name: "Extract Audio", category: .audio, symbol: "film.stack",
             tagline: "Save the soundtrack of a video as an audio file.",
             input: drop("a Video", "Drop a video to pull the audio from.", "film")),
        Tool(name: "Convert Audio", category: .audio, symbol: "arrow.triangle.2.circlepath",
             tagline: "Change audio files to MP3, M4A, WAV, FLAC or AIFF.",
             input: drop("Audio", "Drop audio files to convert.", "waveform")),
    ]

    // MARK: Images

    static let images: [Tool] = [
        Tool(name: "Blur Faces", category: .images, symbol: "face.dashed",
             tagline: "Find faces in photos and blur, pixelate or black them out.",
             input: .blurFaces),
        Tool(name: "Beautify Screenshot", category: .images, symbol: "sparkles.rectangle.stack",
             tagline: "Put screenshots on a soft background with padding, rounded corners and a shadow.",
             input: .beautifyScreenshot),
        Tool(name: "Remove Background", category: .images, symbol: "person.crop.rectangle",
             tagline: "Lift the subject out of photos and save it with a transparent or solid background.",
             input: .removeBackground),
        Tool(name: "Convert Images", category: .images, symbol: "arrow.triangle.2.circlepath",
             tagline: "Save photos as HEIC, WebP, JPG, JPEG or PNG.",
             input: .convertImages),
        Tool(name: "Compress Images", category: .images, symbol: "arrow.down.right.and.arrow.up.left",
             tagline: "Make photos smaller without visible loss in quality.",
             input: .compressImages),
        Tool(name: "Resize Images", category: .images, symbol: "arrow.up.left.and.arrow.down.right",
             tagline: "Scale photos by percentage, longest side or exact size.",
             input: drop("Images", "Drop images to resize.", "photo")),
        Tool(name: "Rotate Images", category: .images, symbol: "rotate.right",
             tagline: "Rotate or flip many photos at once.",
             input: drop("Images", "Drop images to rotate or flip.", "photo")),
        Tool(name: "Remove Metadata", category: .images, symbol: "location.slash",
             tagline: "Strip location, camera and date info from photos.",
             input: drop("Photos", "Drop photos to clean.", "photo")),
        Tool(name: "Color Picker", category: .images, symbol: "eyedropper",
             tagline: "Pick any color on screen and copy it as HEX, RGB, HSL or code.",
             input: .live(symbol: "eyedropper", idle: "Pick a color from anywhere on screen.", action: "Pick Color")),
        Tool(name: "Redact Image", category: .images, symbol: "eye.slash",
             tagline: "Hide names, faces and private details in an image.",
             input: drop("an Image", "Drop an image to redact.", "photo")),
        Tool(name: "Annotate Screenshot", category: .images, symbol: "pencil.and.outline",
             tagline: "Add arrows, boxes, numbers and text to a screenshot.",
             input: drop("a Screenshot", "Drop a screenshot to annotate.", "photo")),
    ]

    // MARK: Docs (13 of 22 tools are visible in the design so far)

    static let docs: [Tool] = [
        Tool(name: "Scan Document", category: .docs, symbol: "doc.viewfinder",
             tagline: "Scan paper with your iPhone or from photos. Pages are found, straightened and cleaned up.",
             input: drop("Photos", "Drop photos of paper, or scan with your iPhone.", "doc.viewfinder")),
        Tool(name: "Redact PDF", category: .docs, symbol: "eye.slash",
             tagline: "Black out names, numbers or whole areas so they're removed for good, not just covered up.",
             input: drop("a PDF", "Drop a PDF to redact.", "doc.richtext")),
        Tool(name: "Fill & Flatten Forms", category: .docs, symbol: "square.and.pencil",
             tagline: "Fill in PDF forms, add text where there are no fields, and flatten the answers so they print as-is.",
             input: drop("a PDF", "Drop a PDF form to fill in.", "doc.richtext")),
        Tool(name: "Make PDF Searchable", category: .docs, symbol: "text.magnifyingglass",
             tagline: "Add an invisible text layer to scanned PDFs so you can search, select and copy their text.",
             input: drop("PDFs", "Drop scanned PDFs to make searchable.", "doc.richtext")),
        Tool(name: "PDF to Word", category: .docs, symbol: "doc.text",
             tagline: "Turn PDFs into Word documents you can edit, with headings, lists and paragraphs.",
             input: drop("PDFs", "Drop PDFs to convert to Word.", "doc.richtext")),
        Tool(name: "Sign PDF", category: .docs, symbol: "signature",
             tagline: "Draw or type your signature and place it on a document.",
             input: drop("a PDF", "Drop a PDF to sign.", "doc.richtext")),
        Tool(name: "Merge PDFs", category: .docs, symbol: "doc.on.doc",
             tagline: "Combine several PDFs and images into one document.",
             input: drop("PDFs", "Drop PDFs and images to combine.", "doc.richtext")),
        Tool(name: "Split PDF", category: .docs, symbol: "scissors",
             tagline: "Break a PDF into single pages or page ranges.",
             input: drop("a PDF", "Drop a PDF to split.", "doc.richtext")),
        Tool(name: "Organize PDF", category: .docs, symbol: "square.grid.3x3",
             tagline: "Reorder, rotate and remove pages in a PDF.",
             input: drop("a PDF", "Drop a PDF to organize.", "doc.richtext")),
        Tool(name: "Delete Pages", category: .docs, symbol: "minus.square",
             tagline: "Remove the pages you don't need from a PDF.",
             input: drop("a PDF", "Drop a PDF to remove pages from.", "doc.richtext")),
        Tool(name: "Extract Pages", category: .docs, symbol: "square.and.arrow.up.on.square",
             tagline: "Save selected pages as a new PDF.",
             input: drop("a PDF", "Drop a PDF to extract pages from.", "doc.richtext")),
        Tool(name: "Images to PDF", category: .docs, symbol: "photo.on.rectangle.angled",
             tagline: "Turn photos and scans into a single PDF document.",
             input: drop("Images", "Drop photos or scans to combine.", "photo")),
        Tool(name: "Compress PDF", category: .docs, symbol: "arrow.down.right.and.arrow.up.left",
             tagline: "Make PDFs smaller by recompressing their images.",
             input: drop("PDFs", "Drop PDFs to shrink.", "doc.richtext")),
    ]

    // MARK: Text & Speech

    static let textAndSpeech: [Tool] = [
        Tool(name: "Transcribe", category: .textAndSpeech, symbol: "text.bubble",
             tagline: "Turn speech in audio and video into a timestamped transcript.",
             input: drop("Audio or Video", "Drop a recording to transcribe.", "waveform")),
        Tool(name: "Summarize", category: .textAndSpeech, symbol: "text.alignleft",
             tagline: "Summarize text and documents on device with Apple Intelligence.",
             input: .text),
        Tool(name: "Extract Text", category: .textAndSpeech, symbol: "text.viewfinder",
             tagline: "Recognize text in images, screenshots and scanned PDFs.",
             input: drop("an Image or PDF", "Drop images or scanned PDFs to read.", "photo")),
        Tool(name: "Capture Text", category: .textAndSpeech, symbol: "viewfinder",
             tagline: "Select any area of the screen and copy the text in it.",
             input: .live(symbol: "viewfinder", idle: "Select an area of the screen to copy its text.", action: "Capture Text")),
        Tool(name: "Translate", category: .textAndSpeech, symbol: "character.bubble",
             tagline: "Translate text, documents and subtitles on device, keeping their formatting and timing.",
             input: .text),
        Tool(name: "Text to Speech", category: .textAndSpeech, symbol: "speaker.wave.2",
             tagline: "Turn text, documents and PDFs into natural speech, and save it as audio.",
             input: .text),
        Tool(name: "Ask a Document", category: .textAndSpeech, symbol: "questionmark.bubble",
             tagline: "Ask questions about a PDF or document and get answers with page references.",
             input: drop("a Document", "Drop a PDF or document to ask about.", "doc.text")),
    ]

    // MARK: Files

    static let files: [Tool] = [
        Tool(name: "QR Code", category: .files, symbol: "qrcode",
             tagline: "Make QR codes for links, text and Wi-Fi, or read codes and barcodes from images.",
             input: .text),
        Tool(name: "Batch Rename", category: .files, symbol: "textformat.123",
             tagline: "Rename many files at once with find and replace, numbering, dates or case changes.",
             input: drop("Files", "Drop files or folders to rename.", "doc.on.doc")),
        Tool(name: "Find Duplicates", category: .files, symbol: "square.on.square",
             tagline: "Find identical files across folders and move the extras to the Trash.",
             input: drop("Folders", "Drop folders to scan for duplicates.", "folder")),
        Tool(name: "Zip & Unzip", category: .files, symbol: "doc.zipper",
             tagline: "Open ZIP, RAR, 7z and TAR files, or make a ZIP, with a password if you like.",
             input: drop("Files", "Drop files to zip, or an archive to open.", "doc.zipper")),
    ]

    // MARK: Mac

    static let mac: [Tool] = [
        Tool(name: "Network Speed Test", category: .mac, symbol: "gauge.with.dots.needle.67percent",
             tagline: "Measure download, upload and responsiveness with Apple's own network test.",
             input: .mac(.networkSpeedTest)),
        Tool(name: "Storage Explorer", category: .mac, symbol: "internaldrive",
             tagline: "See what's filling your disk, find the usual space hogs and clear them out safely.",
             input: .mac(.storageExplorer)),
        Tool(name: "Wi-Fi Password & QR", category: .mac, symbol: "wifi",
             tagline: "Show the password of a saved Wi-Fi network and make a QR code guests can scan to join.",
             input: .mac(.wifiPassword)),
        Tool(name: "Keep Awake", category: .mac, symbol: "cup.and.saucer",
             tagline: "Stop your Mac from sleeping during downloads, renders or talks, for as long as you choose.",
             input: .mac(.keepAwake)),
        Tool(name: "Uninstall App", category: .mac, symbol: "trash",
             tagline: "Remove an app together with the caches, preferences and data it leaves behind.",
             input: .mac(.uninstallApp)),
        Tool(name: "Presentation Mode", category: .mac, symbol: "rectangle.on.rectangle",
             tagline: "One switch before you share your screen: hide desktop icons, hide the Dock and stay awake.",
             input: .mac(.presentationMode)),
        Tool(name: "Clean Keyboard", category: .mac, symbol: "keyboard",
             tagline: "Pause the keyboard for a minute so you can wipe the keys without typing gibberish.",
             input: .mac(.cleanKeyboard)),
        Tool(name: "Eject All Disks", category: .mac, symbol: "eject",
             tagline: "Safely eject every external drive, card and disk image at once before you unplug.",
             input: .mac(.ejectAllDisks)),
        Tool(name: "Login & Background Items", category: .mac, symbol: "switch.2",
             tagline: "See what starts with your Mac and runs in the background, who made it, and turn off what you don't need.",
             input: .mac(.loginItems)),
        Tool(name: "Fix \"App Is Damaged\"", category: .mac, symbol: "exclamationmark.triangle",
             tagline: "Check who made an app that won't open, then clear the download quarantine so macOS lets it run.",
             input: .mac(.fixDamagedApp)),
        Tool(name: "Reset Permissions", category: .mac, symbol: "lock.rotation",
             tagline: "Unstick an app's Screen Recording, Microphone, Camera or other privacy access.",
             input: .mac(.resetPermissions)),
        Tool(name: "Hidden Settings", category: .mac, symbol: "slider.horizontal.3",
             tagline: "Switch on useful macOS settings that aren't in System Settings, like a faster Dock or hidden files.",
             input: .mac(.hiddenSettings)),
        Tool(name: "Display Control", category: .mac, symbol: "display",
             tagline: "Change the brightness, contrast and volume of external monitors, right from your Mac.",
             input: .mac(.displayControl)),
        Tool(name: "Mouse Fixes", category: .mac, symbol: "computermouse",
             tagline: "Scroll your mouse and trackpad in different directions, and make the mouse wheel faster.",
             input: .mac(.mouseFixes)),
    ]

    // MARK: Developer (4 of 8 tools are visible in the design so far)

    static let developer: [Tool] = [
        Tool(name: "Hash Generator", category: .developer, symbol: "number",
             tagline: "Create MD5, SHA-1 and SHA-256 hashes of text or files.", input: .text),
        Tool(name: "Diff Checker", category: .developer, symbol: "arrow.left.arrow.right",
             tagline: "Compare two blocks of text and see what changed.", input: .text),
        Tool(name: "Base64", category: .developer, symbol: "textformat.abc.dottedunderline",
             tagline: "Encode and decode Base64.", input: .text),
        Tool(name: "JSON Formatter", category: .developer, symbol: "curlybraces",
             tagline: "Format, validate and minify JSON.", input: .text),
    ]
}
