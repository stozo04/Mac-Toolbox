> Dated record from 2026-11-17, kept for history. The code has moved on since; check `main` before acting on anything here.

# Toolbox code review: nuances, optimizations, standards

**Date:** 2026-11-17
**Code reviewed:** `origin/main` @ `99ea660` (feat: build Trim Audio (#28)), read in a clean worktree. Your local `feat/trim-audio` branch has no content difference from main (`git diff origin/main HEAD` is empty): #28 squash-merged all of it, so the branch can go.
**Why:** PR #30 ([stozo04/Mac-Toolbox#30](https://github.com/stozo04/Mac-Toolbox/pull/30)) found one test that crashed the whole run because it read `lines[0]` from `pmset` output that wasn't there yet. This review looks for more of that kind of bug, plus everything else at the same depth.
**How:** five read-only reviews in parallel (tests, processes and concurrency, repo promises, performance, standards). I then re-read the cited lines for every finding marked ✅. I built and ran one thing: a build with strict concurrency checking (see C5). I ran no tests.

**Labels used throughout:**
- ✅ = I read the cited code and confirmed the mechanism. The downstream effect is reasoned, not reproduced.
- 🔎 = reported by a reviewer and plausible, but I haven't re-read it myself.
- 🏃 = measured by running something.

Memory and time figures (GB, number of walks) are arithmetic from image sizes and counts. None of them were measured.

Effort: **S** (under 1 hour), **M** (half a day), **L** (a day or more).

---

## Top 10: where I'd start

| # | Finding | Why first | Effort |
|---|---|---|---|
| 1 | T1 About 25 more places that can crash the whole test run (PR #30 fixes only its own two) | The same bug class as PR #30. It kills the entire CI run | M |
| 2 | T2 Waits with no deadline in tests (30 sites) | One failed media writer hangs CI for the full 45-minute job | S |
| 3 | R2 Find & Redact silently skips OCR, then reports "No matches" | The user trusts a redaction that missed things | M |
| 4 | P1 Locking the vault blocks the main thread, with no time limit | The app freezes on sleep, screen lock and quit | M |
| 5 | U1 Drag-and-drop loses the "skipped files" notice (17 copies) | A user-facing bug that comes and goes, multiplied by copy-paste | S, if done with D1 |
| 6 | V1 Vault reloads its whole library after every file moved in | Importing into a big vault gets slower and slower and stutters | S |
| 7 | T5 1,685 leaked test preference files on this Mac | Tests leave junk on the real Mac 🏃 | S |
| 8 | C1 `Shell` cancel race, and timeouts that never escalate | Pressing Cancel doesn't stop ffmpeg or yt-dlp | M |
| 9 | C3 Cancelling a transcription is logged as an error | Feeds false errors into the log-fixer pipeline | S |
| 10 | S1 "Update yt-dlp" installs a downloaded binary with no checksum check | It runs network code nobody verified. It only happens when the user clicks Update, because the bundled copy is used first | S |

---

## 1. Tests: the PR #30 kind of bug (crashes, races, leaks)

The key fact: XCTest's `continueAfterFailure` is `true`. So `XCTAssertEqual(x.count, 1)` followed by `x[0]` does **not** protect anything. A wrong count still traps, and the whole process dies along with every result after it.

**T1. Tests that crash the run instead of failing one test.** ✅ (PR #30's sites), 🔎 (the rest)
- **PR #30's own sites:** `Tests/ToolboxTests/MacPowerTests.swift:61-63` and `:71-73` (✅). PR #30 fixes these once it merges. Everything below is outside PR #30.
- **Track lists from AVFoundation indexed with `[0]`:** `CompressVideoTests.swift:116,122,134,141,154,156,179,191`, `MuteVideoTests.swift:37,50,151-152`, `BurnInSubtitlesTests.swift:221`.
- **The pattern "assert the count, then subscript":**
  - `ExtractFramesTests.swift:95-107`
  - `ScanDocumentTests.swift:207-209`
  - `StorageExplorerTests.swift:36-37` (this one walks a real temp folder)
  - `MacAppToolsTests.swift:279-285`
  - `VaultLikelyDuplicatesTests.swift:122`
  - `ColorPickerTests.swift:283-288`
  - `LoggingTests.swift:27-29,93`
- **Force unwraps on results from the code under test:** `AnnotateScreenshotTests.swift:44,57,279,290,575,579,598,609`, `MacAppToolsTests.swift:186-187,324`, `StorageExplorerTests.swift:26,101`.
- **Pixel helpers that index raw buffers with no bounds check:** `ConvertImagesTests.swift:332-338`, `AnnotateScreenshotTests.swift:45`, and the `at(_:_:)` helpers in BlurFaces, Beautify, RedactImage and RemoveBackground tests.
- **Fix:** use `try XCTUnwrap(x.first)`, or `guard x.count == n else { return XCTFail(...) }`. Add a SwiftLint custom rule that bans `\[0\]` and `!` force unwraps under `Tests/` so the pattern can't come back. **M**

**T2. Waits with no deadline can hang CI until the 45-minute timeout.** ✅
- **Media writers (11 sites):** loops like `while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }` never check `writer.status`. If the writer fails, the loop spins forever. Sites: `VaultTestMedia.swift:19,61`, CompressVideo:346, BurnIn:293, ExtractFrames:198, ExtractAudio:489, MuteVideo:210, MediaInfo:191, ResizeVideo:120, TrimVideo:80, VideoToGif:89.
- **Unbounded `while m.phase != .ready` polls (19 sites):** in `MacNetworkTests`, `MacAppToolsTests` (✅ :205), `DownloadVideoTests` and `StorageExplorerTests`.
- **Fix:** write one shared `waitUntil(timeout:_:)` in a test-support file that throws when time runs out, and throw on `writer.status == .failed`. Three places already have their own version of this: VaultTests, AIModelsTests, and PR #30's `lines(naming:settlingOn:)`. **S**

**T3. Fixed sleeps standing in for "wait until ready".** ✅ / 🔎
- **Trim Audio (✅):** `TrimAudioTests.swift:243-248` checks `isReadyToPlay` after a flat 200 ms sleep. This is the same race your branch's commit c2696a4 fixed in the app, and it is still in the test.
- **Hidden Settings debounce:** `MacPowerTests.swift:261` waits 1100 ms for a 700 ms debounce.
- **Vault lock:** `VaultTests.swift:151-153` sleeps 100 ms. It also has no `defer` to lock the vault again, so a failure leaves the encrypted image mounted.
- **FSEvents warm-up:** `AIModelsTests.swift:511`.
- **Fix:** poll for the condition with a deadline. **S**

**T4. Tests that pass without testing anything.** 🔎
- **Where:** `ConvertImagesTests.swift:226`, `MuteVideoTests.swift:123`, `ExtractAudioTests.swift:254,260,277,286`.
- **What happens:** these use bounded loops like `for _ in 0..<400 where !isRunning`. When the loop runs out, the test carries on silently, so the race it was meant to exercise never happens.
- **Fix:** call `XCTFail` when the loop runs out. **S**

**T5. Tests leak state onto the real Mac.**
- **Preference files 🏃:** there are **1,685** test plists in `~/Library/Preferences` right now (`color-picker-*`, `com.toolbox.tests.*`, `toolbox.tests.*`). `removePersistentDomain` runs *before* each test, never after. Fix: use `addTeardownBlock`.
- **Clipboard ✅:** `ColorPickerTests.swift:414-422` writes to `NSPasteboard.general` and doesn't restore it, so running the tests wipes your clipboard. Fix: inject a named pasteboard, as Annotate's tests do.
- **Privacy database ✅:** `MacAppToolsTests.swift:127-130` runs a real `tccutil reset` against your privacy database. Fix: put it behind an opt-in env var.
- **Log state 🔎:** `Log` is global to the process, so `LoggingTests` depends on test order.
- **Effort:** **S**

**T6. Skipped tests that CI never runs.** 🏃
- **What the logs show:** main's last CI run reports "718 tests, 8 skipped". Four of the skips are opt-in live tests (DDC write, real download, Supabase, speed test), which is fine.
- **Vault search:** the other four are **every `VaultSearchTests` real-model test** (`:96,172,186,212`). They skip because CI never downloads EmbeddingGemma, so real search is never tested in CI.
- **MP3 tests:** they do run on CI today. But `ExtractAudioTests.swift:358` would skip 8 of them silently if the tools cache broke. `VaultPlayableTests` fails on `CI == "true"`, so copy that guard.
- **Decision needed:** cache the model in CI, or accept the gap and print a warning in the job summary. **S/M**

---

## 2. Repo promises (AGENTS.md rules the code breaks)

**R1. Redact PDF's "would overwrite the original" check compares paths, not files.** 🏃 (narrowed)
- **Where:** `RedactPDF.swift:185`.
- **What's wrong:** the check compares path strings (`BatchFiles.identity`).
- **Not a problem:** the reviewer's case-variant scenario (`contract.pdf` vs `Contract.pdf`). I ran it: `resolvingSymlinksInPath` returns the on-disk case for an existing file, so both names resolve the same and the check catches it.
- **What's left:** a hard link, or another path to the same file, still gets past it. That's rare.
- **Fix:** compare `.fileResourceIdentifierKey`. Low priority. **S**

**R2. Find & Redact can miss text and say "No matches".** ✅ / 🔎
- **Skipped pages ✅:** `RedactPDF.swift:139` skips OCR on any page with *any* text layer. A scan with a stamped page number is never read.
- **Swallowed failures 🔎:** Vision failures are swallowed and become an empty result (`:160,168`).
- **Weak verify step 🔎:** it doesn't search the output again. It samples the box centres and four info keys, and doesn't look at annotations or form values on pages without boxes (`:278-286`).
- **Fix:**
  - OCR pages that have images or very little text.
  - Report "N pages could not be searched".
  - After export, run `findString` on the output and fail on any hit outside a box. **M**

**R3. Redact Image's default style can be reversed on text.** 🔎
- **What's wrong:** the default is Blur. Pixelate blocks come out about 6 px on 14 px text, and pixelated text can be recovered ([Depix](https://github.com/spipm/Depix)). Whether these exact settings are recoverable hasn't been tested. The comment at `RedactImage.swift:293` promises "nothing underneath can be recovered". That is only true for Black Box.
- **Fix:** default to Black Box when the regions come from finding text, and warn when blur or pixelate is used on text. **S**

**R4. Vault move edge cases.** ✅ / 🔎
- **Partial copy left behind ✅:** `copyItem` runs *outside* the cleanup `do` (`VaultMover.swift:77`). If the disk fills mid-copy, a truncated file can stay in the vault.
- **External eject 🔎:** if the image is detached outside the app mid-move, the copy lands in the plain mount-point folder on the boot disk. It passes the hash check, and the original is deleted.
  - Fix: check the destination's volume identifier before deleting.
  - Also refuse to mount onto a non-empty mount point.
- **No fsync 🔎:** nothing syncs the copy to disk before the original is deleted.
- **Effort:** **S/M**

**R5. Log scrubbing misses query strings.** ✅
- **What's wrong:** `LogText.clean` (`Support/Logging/LogDetails.swift:8`) only rewrites `/Users/<name>`. yt-dlp's stderr ("ERROR: Unsupported URL: https://…?sig=…") goes into `error_description`, so tokens can reach Supabase.
- **Fix:** strip `?…` from any URL inside `clean`. **S**

**R6. Failures swallowed with no message and no `Log.details`.** 🔎
- **Silent failures:**
  - `WifiPasswordView.swift:128` (saving the QR)
  - `AnnotateScreenshotModel.swift:415` (drag-out)
  - `BatchFiles.swift:38` (`try? createDirectory`; every later per-file error is then misleading)
- **Error detail thrown away:** `RedactPDF.swift:218` drops the underlying error.
- **Trim Video:** its output isn't given a unique name, and its fallback deletes an earlier output that shares the name (`VideoTrimmer.swift:44,51`).
- **Effort:** **S**

---

## 3. Processes and concurrency

**P1. Locking the vault blocks the main thread.** ✅
- **What happens:** on sleep, screen lock and quit, `lockImmediately` runs on main. It calls `VaultSearchEngine.close()`, which waits on a semaphore for up to 3 s (`VaultSearchEngine.swift:148-156`). It then runs `diskutil eject` and `hdiutil detach -force` synchronously, with no timeout (`VaultDisk.swift:104-108`).
- **Impact:**
  - If the disk-image helper is stuck, the app hangs and quit hangs.
  - Mouse Fixes' event tap runs on main, so mouse-wheel scrolling stalls system-wide while main is blocked.
- **Fix:**
  - Make the lock path async: await `shutDown()` with a timeout.
  - Run the commands through `Shell.run(timeout:)`.
  - Use `applicationShouldTerminate` → `.terminateLater`. **M**

**C1. `Shell.run` problems.** ✅ / 🔎
- **Cancel race ✅:** if Cancel lands between the `Task.isCancelled` check and `process.run()`, `ProcessBox.terminate()` does nothing, because the process isn't running yet. ffmpeg or yt-dlp then runs to completion.
  - Fix: add a locked `cancelled` flag and check it after `run()`.
- **Timeouts 🔎:** they only send SIGTERM and never escalate to SIGKILL. A timeout shows up as an ordinary exit with status 15 and an empty error.
- **Missing timeouts 🔎:** about 10 call sites have none: `hdiutil info`, `diskutil image attach`, `networksetup`, ffprobe and others.
- **Lost output 🔎:** the end of stdout can be lost, because clearing `readabilityHandler` doesn't wait for a handler that is already running.
- **Effort:** **M**

**C2. Child processes outlive the app.** 🔎
- **What's wrong:** nothing terminates running ffmpeg or yt-dlp on quit.
- **Impact:** a cancelled or quit download leaves `.part` files in Downloads, and a trim leaves a truncated output.
- **Fix:**
  - Keep a registry of live processes and kill them on terminate.
  - Have yt-dlp write to a temp folder (`-P temp:`). **M**

**C3. Cancelling a transcription is reported as a failure and logged as an error.** ✅
- **Where:** `SpeechTranscriber.swift:86`.
- **Why:** `Task.isCancelled` is checked inside the Speech framework's callback, which isn't the Swift task, so it's always false.
- **Impact:** Cancel in Burn In Subtitles becomes `SpeechError.failed` plus a `Log.error` to Supabase, which can trigger pointless log-fixer PRs.
- **Fix:** keep a cancelled flag behind a lock in the `Box`. **S**

**C4. Stale results overwrite newer ones, and cancels that don't reach detached work.** 🔎
- **Color Picker:** a late palette overwrites a newer one (`ColorPickerModel.swift:165`).
- **Trim Audio:** a cancelled save resets a newer save's state (`TrimAudioModel.swift:260-276`); the waveform decode can't be cancelled (`:126`).
- **Storage Explorer:** a late measurement overwrites a newer one.
- **Screen recording:** `ScreenRecorder.stop()` tears down `highlighter` and `micSession` off its capture queue (`ScreenRecorder.swift:262-292`), so it can crash at the moment you press Stop.
- **Annotate (✅ mechanism, low likelihood, privacy):** `AnnotateBlurCache` identifies its source image by `ObjectIdentifier` alone (`AnnotateScreenshot.swift:389-401`). If a new screenshot reuses the freed address of the old one, blur regions would show blurred pixels of the *previous* screenshot. That needs address reuse while the cache is still alive, so it's unlikely, but it's a two-line fix.
  - Fix: keep a strong reference and compare with `===`.
- **Supabase log sink:** it can drop unsent events when its queue trims during a send (`SupabaseLogSink.swift:57,76`).
- **Effort:** **S each**

**C5. Moving to Swift 6 costs less than it sounds.** 🏃
- **Measurement:** `swift build -Xswiftc -strict-concurrency=complete` on main gives **38 unique warnings in 15 files**, about 34 of them concurrency:
  - ModelsView: 7
  - VideoCompressor: 7
  - RecordScreenModel: 4
  - VaultSearchEngine: 3
  - MainWindowReopener: 3
  - the rest are 1 or 2 per file
  - The other ~4 are a deprecation, an unneeded `try`, and implicit-capture notes.
- **Scope:** this covers the app target only. The test target wasn't built with the flag.
- **Races:** I didn't check whether any of the warnings is a live race. The `VideoCompressor` ones look benign: the captured vars are only touched on one serial queue.
- **Recommendation:** move to `swift-tools-version: 6.0` with Swift 6 language mode on the Toolbox target in one PR. Most fixes are `sending`/`@MainActor` annotations. **M**

**S1. yt-dlp is installed with no integrity check.** ✅
- **Where:** `YtDlpDownloader.swift:168-178`.
- **When it runs:** only when the user clicks "Update yt-dlp" (`DownloadVideoModel.swift:99`). After that, `findYtDlp` picks whichever is newer, the bundled copy or the downloaded one, so the unverified download wins.
- **What's wrong:**
  - It downloads `releases/latest` and `chmod 755`s it after only a status-200 check. The Vault model download does check a pinned SHA-256.
  - The old binary is deleted before the move, so a failed move leaves no yt-dlp at all.
  - The `$TOOLBOX_YTDLP` override also works in release builds.
- **Fix:**
  - Verify against yt-dlp's `SHA2-256SUMS`.
  - Swap the binary in with `replaceItemAt`.
  - Allow the override in DEBUG builds only. **S**

---

## 4. Performance and memory

**V1. The Vault walks its whole library after every file moved in.** ✅
- **Where:** `VaultModel.swift:355-356`.
- **What's wrong:** `moveProgress?.done += 1; reload()` runs a full enumerator walk, a sort, a prune, a trash summary and durations, all on `@MainActor`.
- **Impact:** 500 files into a 5,000-item vault means 500 full walks.
- **Fix:** add items as they arrive, then do one reload off main at the end. **S**

**V2. The Vault thumbnail cache never shrinks.** ✅
- **Where:** `VaultThumbnails.swift:40` holds `[String: CGImage]`.
- **Impact:** about 0.9 MB per thumbnail, so scrolling 5,000 items holds about 4 GB until lock. Tiles you've already scrolled past still decode.
- **Fix:** use `NSCache` with `totalCostLimit`, and check `Task.isCancelled` before decoding. **S**

**V3. Other Vault costs.** 🔎
- **Lists recomputed on every redraw:** `displayedItems` and `searchSections` (`VaultModel.swift:393-415`).
- **Search re-run per indexed file:** a full search runs after every indexed file, and the cached vectors are thrown away after each store (`VaultSearchEngine.swift:88`).
- **SQLite:** `VaultIndex.remove` runs one commit per path with no transaction, and there is no WAL.
- **Import:** every file is read three times on import (copy, then two hashes).
- **Viewer:** it decodes full-size images.
- **Effort:** **M**

**V4. Scan Document keeps every page as a full bitmap, forever.** ✅
- **Where:** the model is a `.shared` singleton holding `let image: CGImage` per page.
- **Impact:** 50 iPhone photos is about 2.4 GB, and a 200-page PDF at 200 dpi is about 3 GB. None of it is released after you leave the tool.
- **Fix:** keep a working copy around 1600 px (or a temp file) and render full size only in `makePDF`. **M**

**V5. Storage Explorer.** ✅ / 🔎
- **Clear on main ✅:** `clearSelected()` runs `StorageCleaner.clear` on main (`StorageExplorerModel.swift:88`), so emptying a large Trash beachballs the app.
- **Explore 🔎:** it starts one child task per entry, each running a synchronous walk, which starves the shared task pool. Each result then triggers a full sort and a re-layout of a non-lazy `VStack`.
- **Fix:** run the walks on a limited-width queue, apply results in batches, use `LazyVStack`, and run Clear off main. **M**

**V6. The AI Models page never stops watching once opened.** ✅
- **Where:** `ModelsView.swift` calls `library.start()` in `onAppear` and never calls `stop()`.
- **Impact:** the FSEvents watch on `~/Library/Application Support` and `~/Library/Caches`, a Spotlight query, a 10 s poll, and a full rescan with `lsof` on every app activation all keep running for the whole session.
- **Fix:** call `stop()` in `onDisappear`, and debounce the activation trigger. **S**
- **Watch out:** `stop()` leaves `scanning` non-nil (`ModelLibrary.swift:67`), so fix that at the same time.

**V7. Smaller hot spots.** 🔎
- **Remove Background:** re-runs the Vision mask on every color-picker change. Cache the mask per URL.
- **Blur Faces:** decodes full resolution just to find faces. Detect on a 2048 px thumbnail instead.
- **Trim Audio:** redraws all 400 waveform bars 30 times a second, because the playhead lives in the same body as the canvas. Split it into its own view.
- **Batch tools:** walk dropped folders on main.
- **AI Models:** looks up app icons in the view body.
- **Effort:** **S each**

---

## 5. Standards and architecture

**D1. The batch-queue model is copy-pasted 17 times.** ✅
- **What's copied:** each of 17 tool models carries the same `Status`, `Item`, `add`/`remove`/`clear`, `runID`-guarded run loop, `notice`, and `reveal`.
- **Effect:** U1 below is a 17-file fix, and about 10 of these models have no tests.
- **Fix:** write a generic `@Observable BatchQueue` that each tool feeds a per-file `process` closure, and test it once. **L**

**U1. Drag-and-drop loses the "skipped files" notice.** ✅
- **Where:** `MuteVideoView.swift:40-46` and about 20 views like it.
- **What's wrong:** these views call `model.add([url])` once per dropped item, and `add` resets `notice` each time.
- **Scenario:** drop `notes.txt` and `clip.mov` together. Whether you're told about the skipped file depends on which one loads last.
- **Fix:** a shared `.fileDrop { urls in }` modifier that collects all providers, then calls `add` once. **S** (17 call sites)

**D2. More duplication worth pulling out.** 🔎
- **ffmpeg handling:** the run, cleanup and error code is duplicated between `AudioExtractor.swift:192-210` and `AudioTrimmer.swift:62-81`. `FFmpegProgress` lives inside ExtractAudio.
- **Image writing:** about 10 tools hand-roll `CGImageDestination` writes. The shared `ImageConverter` lives inside `Tools/Images/ConvertImages/`.
- **Unique names:** generated five different ways.
- **`NSOpenPanel`:** set up by hand in 27 places.
- **Shared UI inside single tools:** `TimeField` sits in TrimVideoView and `CleaningOverlayView` inside a model file.
- **Fix:** move these into `Support/`. **M**

**D3. `ToolInput.isImplemented` ends in `default: true`.** ✅ (trade-off, not a bug)
- **Where:** `Models/Tool.swift:66-71`.
- **Why it's like this:** it's deliberate. A new tool loses its banner just by getting its own case.
- **The cost:** the AGENTS.md rule ("keep placeholder cases out of `default`") relies on people remembering it, because the compiler can't enforce it.
- **Fix:** list every case explicitly. That costs one line per new tool. **S**

**D4. Lint never fires, and swift-format isn't tracked.** ✅ / 🔎
- **SwiftLint limits ✅:** file 1000/2500, function 120/400 and cyclomatic 25/60 are all above the actual worst cases (largest file 756 lines, longest function about 88 lines). They will never fire.
- **swift-format ✅:**
  - It is `continue-on-error: true` with no tracking issue, which your house rules require.
  - Its `lineLength` is 160 while SwiftLint's is 200.
- **Fix:**
  - Ratchet the limits down (file 600/800, function 60/100, cyclomatic 12/20).
  - Open the tracking issue.
  - Pick one line length.
  - Then make swift-format blocking. **S**

**D5. AGENTS.md rules a script could check but CI doesn't.** 🔎
- **Rules:** RevealButton and no magnifying glass for reveal, `Theme.*` and no hardcoded white/black (64 matches, mostly defensible scrims), the network allowlist, and the `ToolInput` placeholder rule.
- **Fix:**
  - Add a `scripts/check-rules.sh` CI job.
  - Add `Theme.scrim` and `Theme.onAccent` first, so the color rule has the vocabulary it needs.
- **Effort:** **M**

**D6. `${{ github.base_ref }}` is used directly in a `run:` step.** ✅
- **Where:** the "Version bumped" job in `ci.yml`.
- **Risk:** low, but your house rule says to pass such values through `env:`.
- **Effort:** **S**

**D7. Accessibility.** 🔎
- **Icon-only buttons:** at least 41. Of these, 33 have `.help` but no `.accessibilityLabel`, and 8 have neither (Refresh buttons in four Mac tools, Storage Explorer's "up", and Vault menu/close).
- **Custom canvases:** Annotate, Resize handles, Area Selector and the trim handles expose nothing to VoiceOver.
- **Keyboard:** there are no shortcuts for Save, Start or Cancel in the batch tools.
- **Fix:** an `IconButton` like `RevealButton`, plus `accessibilityAdjustableAction` on the handles. **M**

**D8. Nothing watches the vendored and pinned code.** 🔎
- **What isn't watched:** Dependabot covers only GitHub Actions, so `Sources/CWebP`, the llama.cpp pin, and the ffmpeg/LAME/yt-dlp pins in `scripts/fetch-tools.sh` have no update or advisory watch.
- **Fix:** a monthly scheduled workflow, or a tracking issue. **S**

---

## Things that checked out (no action)

- **Batch image tools:** Convert, Compress, Resize, Rotate and Metadata process one file at a time, off main, with downsampled grids. `runID` guards are correct.
- **Original files:** every batch tool writes through `BatchFiles.uniqueURL` into a new folder. Only Trim Video (R6) slips, plus the hard-link edge case in Redact PDF (R1).
- **Vault move order:** copy, verify, hash, check for cancel, check the original is unchanged, then delete. The app's own lock and sleep paths cancel before detaching.
- **Network rule:** URLSession is used only in Download Video, the Vault model download and the Supabase sink. Media Info's "Open in Maps" button opens maps.apple.com with GPS coordinates when clicked. That isn't on AGENTS.md's allowed list, so add it there.
- **Processes:** no shell strings, no argument injection, and both pipes are drained, so there are no pipe deadlocks.
- **Locks:** most `@unchecked Sendable` types do have real locks.
- **`print(`:** there are none in `Sources/Toolbox`. My first count of 8 was a grep artifact: it matched `fingerprint(`.

---

## Decisions for you

1. **Code-comment rule.** Your global rule says no comments. This repo has 1,024 `///` lines and 163 line comments in 168 of 213 files, and `.swiftlint.yml` describes the style as "documented lines". Options:
   - (a) Allow `///` for a non-obvious *why*, ban narration, and write that into AGENTS.md.
   - (b) Enforce no comments with a lint rule, which means a big churn PR.

   Either way, fix the two stale comments (`BatchFiles.swift:4`, `RecordScreenModel.swift:256`).
2. **Swift 6 language mode now?** It's 38 warnings (C5). I'd do it before D1 and the concurrency fixes, so the compiler checks them.
3. **CI for Vault search.** Cache the EmbeddingGemma model in CI, or accept that real-model search is never tested (T6)?
4. **Redact Image default.** Switch the default to Black Box (R3)? It changes what users see.
5. **Batch.** Should T1, T2, T3 and T5 go out as one "test hardening" PR on top of PR #30, or should PR #30 grow to include them?

## Suggested PR sequence

1. **`fix/test-hardening`** (T1–T5): no app change except the version bump. This is the obvious follow-up to PR #30.
2. **`fix/redaction-safety`** (R2, R3, R5, and R1 since it's in the same file).
3. **`fix/vault-lock-and-import`** (P1, R4, V1, V2).
4. **`fix/shell-processes`** (C1, C2, C3, S1).
5. **`chore/swift6`** (C5), then **`refactor/batch-queue`** (D1 + U1 + D2).
6. **`chore/lint-ratchet`** (D3, D4, D5, D6), then performance (V3–V7) and accessibility (D7) as they fit.
