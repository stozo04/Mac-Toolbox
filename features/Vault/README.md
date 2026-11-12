# Vault

**Page:** top-level, the **Vault** pill next to AI Models (`Page.vault`)
**Code:** `Sources/Toolbox/Vault/`

A password-protected, hidden place for photos and videos. Toolbox is the friendly way in (a bank vault door you unlock), but the files are protected without Toolbox too: they live in an AES-256 encrypted disk image that Finder only opens with the same password.

## Design reference
No screenshot in `images/`. The door is design A (round bank vault door with a spoked wheel) picked in the planning conversation: the wheel turns, then the door swings open on its left hinge and the library fades in.

## Current state
Built (storage, lock screen, move in, delete, viewer). Smart search with EmbeddingGemma 2 is the next PR.

- `VaultDisk` - the encrypted image. `diskutil image create blank --encrypt` (AES-256 APFS sparse bundle, 2 TB cap, only uses what is stored), `diskutil image attach --nobrowse` to a hidden mount point, `diskutil eject` (then `hdiutil detach -force`) to lock, `diskutil image chpass` to change the password. The password goes in through standard input, never as an argument, and is never stored or logged. No `sudo`.
- `VaultLocation` - `~/Library/Application Support/Toolbox/.vault.noindex/Vault.sparsebundle`, mounted at `.../.vault.noindex/Open.noindex`. The folder is a dot folder with Finder's hidden flag set.
- `VaultMover` - moves files in: copy, check size + SHA-256 + that it opens, then delete the original for good. Any failure keeps the original. Refuses non-media, files inside a `.photoslibrary`, iCloud files that are not downloaded, and files already in the vault. Folders expand to the photos and videos inside them. Name clashes become "name 2.ext".
- `VaultLibrary` / `VaultItem` - lists photos and videos in the vault (newest added first), skipping hidden files, so `.toolbox/` and `.metadata_never_index` never show.
- `VaultThumbnails` - Toolbox makes its own thumbnails (ImageIO, AVFoundation) and keeps them inside the vault in `.toolbox/thumbs`, so macOS never caches previews of vault files outside it.
- `VaultModel` - phases setup / locked / opening / open; locks on Lock, leaving the Vault page, sleep, screen lock and quit; a vault left open by a crash or force quit is locked at the next launch.
- `VaultDoorView`, `VaultLibraryView`, `VaultViewer` - the door, the grid (Select, ⌘/⇧-click, Delete key, context menu, drag-and-drop, Add), and the viewer (← / → buttons and arrow keys, Esc, videos play inline).
- Tests: `VaultTests.swift`, including a real encrypted image (create, wrong password refused, move in, lock, change password, old password refused).

## Rules for this page
- Moving in deletes the original. This is a deliberate exception to "never modify original user files" (see AGENTS.md).
- Deleting inside the vault is permanent (no Trash), after a confirmation.
- Vault logs never carry file names: `VaultLog` keeps the extension and size only and scrubs the name out of error text.
- Spotlight: nothing is indexed on the mounted volume (nobrowse mount, `.noindex` path, `.metadata_never_index`). DigUp skips it too: its crawler ignores hidden folders, packages and `.noindex` folders.
- No network.

## Debugging
```
.build/debug/Toolbox --page Vault --vault-folder /tmp/vault-test
```
`--vault-folder` puts a test vault anywhere instead of the real one. Debug builds only: `--vault-debug-password <pw>` pre-fills the password fields and `--vault-debug-add <folder>` moves that folder's photos and videos in once the door opens (both are compiled out of release builds).
