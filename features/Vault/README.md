# Vault

**Page:** top-level, the **Vault** pill next to AI Models (`Page.vault`)
**Code:** `Sources/Toolbox/Vault/`

A password-protected, hidden place for photos and videos. Toolbox is the friendly way in (a bank vault door you unlock), but the files are protected without Toolbox too: they live in an AES-256 encrypted disk image that Finder only opens with the same password.

## Design reference
No screenshot in `images/`. The door is design A (round bank vault door with a spoked wheel) picked in the planning conversation: the wheel turns, then the door swings open on its left hinge and the library fades in.

## Current state
Built: storage, lock screen, move in, delete, viewer, browsing by kind and length, duplicate grooming, and smart search (EmbeddingGemma 2 on llama.cpp, on device).

- `VaultDisk` - the encrypted image. `diskutil image create blank --encrypt` (AES-256 APFS sparse bundle, 2 TB cap, only uses what is stored), `diskutil image attach --nobrowse` to a hidden mount point, `diskutil eject` (then `hdiutil detach -force`) to lock, `diskutil image chpass` to change the password. The password goes in through standard input, never as an argument, and is never stored or logged. No `sudo`.
- `VaultLocation` - `~/Library/Application Support/Toolbox/.vault.noindex/Vault.sparsebundle`, mounted at `.../.vault.noindex/Open.noindex`. The folder is a dot folder with Finder's hidden flag set.
- `VaultMover` - moves files in: copy, check size + SHA-256 + that it opens, then delete the original for good. Any failure keeps the original. Refuses non-media, files inside a `.photoslibrary`, iCloud files that are not downloaded, and files already in the vault. Folders expand to the photos and videos inside them. Name clashes become "name 2.ext".
- `VaultLibrary` / `VaultItem` - lists photos and videos in the vault (newest added first), skipping hidden files, so `.toolbox/` and `.metadata_never_index` never show.
- `VaultThumbnails` - Toolbox makes its own thumbnails (ImageIO, AVFoundation) and keeps them inside the vault in `.toolbox/thumbs`, so macOS never caches previews of vault files outside it.
- `VaultModel` - phases setup / locked / opening / open; locks on Lock, leaving the Vault page, sleep, screen lock and quit; a vault left open by a crash or force quit is locked at the next launch.
- `VaultDoorView`, `VaultLibraryView`, `VaultViewer` - the door, the grid (Select, ⌘/⇧-click, Delete key, context menu, drag-and-drop, Add, video tiles show their length), and the viewer (← / → buttons and arrow keys follow what the grid shows, Esc, videos play inline from the start).
- `VaultBrowse` - the All / Images / Videos filter (each tab shows its count, and the header's "N items, size" follows the chosen tab) and, under Videos, sorting by length (shortest or longest first; videos whose length can't be read go last). Lengths are read with AVFoundation in the background each time the vault opens and kept in memory only. During a search the filter still applies but the order stays the search ranking.
- `VaultDuplicates` - the View menu's **Duplicates** lists files with exactly the same bytes (same size first, then SHA-256; names don't matter), images and videos alike, biggest waste first, oldest copy first in each set. You pick the copy to keep (refused if a copy changed or vanished since it was compared); the others go to the vault's Trash. Hashes are cached per file while the vault is open, and a new search waits 0.4 s and stops when the vault locks.
- `VaultTrash` - the vault's own Trash, `.toolbox/trash/` inside the encrypted image, shown at the top of the Duplicates view with Put Back All and Empty Trash (permanent, after a confirmation). macOS's Trash is not used: for the hidden `--nobrowse` vault volume it either keeps files where Finder can't reach them (`.Trashes` on the volume) or would show them, with previews, outside the vault.
- `VaultPlayable` - some videos (HEVC with MP3 sound in an .mp4, common in TikTok downloads) have sound AVFoundation can't see, so they played silently and their sound wasn't searchable. When AVFoundation finds no sound track but ffprobe finds one, ffmpeg makes a lossless `.mov` copy (streams copied, not re-encoded) in `.toolbox/playable/`, inside the encrypted image. The viewer plays it and search reads its sound; the vault file itself is never changed. Each video is looked at once: `<key>.checked` (no copy needed) or `<key>.failed` (logged with `VaultLog.failure`) is kept beside the copies, so silent videos aren't probed again and a failed copy isn't retried until the file changes. Videos indexed before this have their sound read once more. Cancelling (leaving the viewer, locking) is never recorded as a result. Unfinished copies are removed when the vault opens; copies of removed videos are pruned. ffmpeg/ffprobe are the ones bundled in Toolbox.app (`MediaTools`).
- Smart search (`Search/`):
  - `VaultSearch` target (`Sources/VaultSearch/`, adapted from DigUp, MIT, see `LICENSE-DigUp`): `LlamaEmbedder` runs EmbeddingGemma 2 through llama.cpp (`Sources/CLlama`, built by `scripts/build-llama.sh` at DigUp's tag and patch) on the GPU; `MediaPieces` turns a photo into a 1024 px JPEG, a video into a frame every 3 s (one per shot) and 30 s sound windows; `Scoring` compares a query with every vector and centres each kind (image, audio) on its own average; `EmbeddingModel` finds the model files (Toolbox's own folder, DigUp's, the Hugging Face cache) by exact size.
  - `VaultSearchEngine` runs it all on one background queue. Every file it writes (the work JPEGs and WAVs, the index) is inside the mounted vault in `.toolbox/`, and it refuses to open anything when the vault isn't mounted. Locking closes it first (3 s at most).
  - `VaultIndex` is `.toolbox/index.sqlite`: one 768-float vector per photo, video frame and sound window, plus each file's size and modified date so changed files are read again. It records which model made its vectors; a different model empties it.
  - `VaultRanking`: "Best matches" are files whose best meaning score is 2 standard deviations above the rest (DigUp's rule) or whose name holds every search word. "Might also match" adds files half a deviation or more above the average: a vault is full of similar photos, and when a third of them show a phone, none of them stands out by 2 deviations. With neither, the 6 nearest show as "No close matches". Videos found by search still open from the start.
  - `VaultModelDownload` downloads the two model files (865 MB) from Hugging Face when neither DigUp nor an earlier download has them, and checks their SHA-256 before keeping them.
  - Indexing starts when the vault opens and after files move in; the full model (about 1 GB) is freed when it finishes, and searches use the text half (about 0.3 GB).
- Tests: `VaultBrowseTests.swift`, `VaultDuplicatesTests.swift`, `VaultPlayableTests.swift` (with an HEVC + MP3 fixture; needs ffmpeg, which CI builds with `scripts/fetch-tools.sh`), `VaultTests.swift`, including a real encrypted image (create, wrong password refused, move in, lock, change password, old password refused); `VaultSearchTests.swift`, including a real-model search (skipped when the model isn't on the Mac, as on CI).

## Rules for this page
- Moving in deletes the original. This is a deliberate exception to "never modify original user files" (see AGENTS.md).
- Delete inside the vault is permanent (no Trash), after a confirmation. Duplicates you don't keep go to the vault's own Trash (`VaultTrash`) instead, inside the encrypted image, until you put them back or empty it.
- Vault logs never carry file names: `VaultLog` keeps the extension and size only and scrubs the name out of error text.
- Spotlight: nothing is indexed on the mounted volume (nobrowse mount, `.noindex` path, `.metadata_never_index`). DigUp skips it too: its crawler ignores hidden folders, packages and `.noindex` folders.
- Network: only the one-time model download from huggingface.co, when you press Download. Nothing from the vault is ever sent; search runs on this Mac.
- Apple silicon only: llama.cpp is built for arm64, and so is the app.

## Debugging
```
.build/debug/Toolbox --page Vault --vault-folder /tmp/vault-test
```
`--vault-folder` puts a test vault anywhere instead of the real one. Debug builds only: `--vault-debug-password <pw>` pre-fills the password fields and `--vault-debug-add <folder>` moves that folder's photos and videos in once the door opens (both are compiled out of release builds).
