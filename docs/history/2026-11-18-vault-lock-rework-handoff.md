> Dated record from 2026-11-18, kept for history. The code has moved on since; check `main` before acting on anything here. This was the handoff plan for PR #40, which merged on 2026-11-19.

> **Draft. This description is the handoff plan for the agent (Opus) finishing this work.** Do the steps in order. Rewrite this description into a normal PR description at step 1.6, before marking the PR ready.

## Where things stand (2026-11-18)

A code review of `main` (`REVIEW-2026-11-17.md` in the main checkout, untracked) was worked through as a series of PRs. Merged: #30, #32, #31, #33, #34, #35, #38. `main` is at **0.11.8** and its CI is green. This branch is the last code PR. After it: a hand test, one tag, an install, and cleanup.

This branch (`fix/vault-lock-rework`, worktree `../Toolbox-vault-door`, version **0.11.9**, `main` merged in at `65b3cd9`) gives the vault's disk one owner, `VaultDoor`: a class with lock-guarded state that runs every unlock, lock, eject, create and password change strictly one at a time, through `Shell.run`. Ownership between copies of the app is a `Vault.lock` file beside the image, held with `flock`. Sleep blocks on the door with one bound (18 s); quit uses `QuitPreparation` and `.terminateLater` (20 s) and is refused once if the vault cannot be locked. Lint: 0 errors, 52 warnings. 46 new tests.

It is **not proven**:
- Its one known flaky test is identified and fixed (step 1.1), but the fix has only run once, and the suite leaves throwaway disk images attached (also step 1.1). Issue #39 describes a similar unidentified failure on another branch.
- "A mount that lands after its attach was cancelled" rests on 36 real probes, not a proof.
- Nothing in it has run in the real app.
- It has had no independent review.

## Rules that are not negotiable

1. **Steven's real vault is untouchable.** It lives at `~/Library/Application Support/Toolbox/.vault.noindex`. Never open, list, mount, eject or write to it. Never run an unscoped `diskutil eject` or `hdiutil detach`. Tests use throwaway vaults in temp folders only.
2. **Never launch a development build without a scratch vault:** `.build/debug/Toolbox --page <page> --vault-folder "$(mktemp -d)"`. On `main` a development run now defaults to `.vault-dev.noindex`, but pass the flag anyway. On 2026-11-18 a bare launch ejected Steven's real vault mid-import. Put this rule in every subagent brief.
3. **Creating the vault and changing its password are never stopped partway** (timer, cancel or quit). They run `.untilFinished`.
4. House rules in `~/.claude/CLAUDE.md` and `AGENTS.md` apply. In particular: no comments except a specific non-obvious why; no `swiftlint:disable`; never weaken a test; a bug in copied code is fixed in every copy; groom before every PR.
5. Two hooks give false positives. `guard-bash.sh` reads a command that contains both `git push` and the text ` -f ` (for example a `gh api` field flag, or a heredoc) as a force-push. `rook-guard` reads `git rebase origin/main` as rebasing main. Run `git push` as its own command, write long text with the Write tool, and use `git merge origin/main`, not rebase. If a hook blocks anything else, stop and tell Steven.

## How CI works now

- Required checks on `main`: "Version bumped", "Lint & format", "Package Toolbox.app". **"Build & test" is not required** (Steven's decision): GitHub's macOS runners often leave it unassigned for 15 minutes and cancel it. A real test failure there is still fixed before merging; an unassigned or cancelled run is not a reason to wait.
- **The test gate is local:** run the full `swift test` before the PR and paste the exact `Executed N tests…` line. Keep the whole log (`swift test > run.log 2>&1`); never filter it in a way that can drop the failure line.
- Docs-only PRs need no version bump and skip the macOS jobs (`scripts/app-untouched.sh`).
- Bugbot is over its Cursor usage limit and posts "couldn't run". That is not a finding. Use the `codex-review` skill for the independent review (`codex review --base origin/main`, run from the worktree; it takes no prompt together with `--base`).
- GitHub can take a few minutes to start a run after a push. Do not close and reopen the PR to hurry it.

## Step 1: finish this PR

**1.1 Finish the flaky-test work.** Five full runs under CPU load (eight `yes > /dev/null &` processes, whole log kept) gave 922 tests and 0 failures four times, and 2 failures once. Both failures were one test, `VaultDoorTests.testAnEjectThatTimesOutStillForcesTheVaultClosed`: its 0.3 s step bound also covered the real `hdiutil detach` that follows the stand-in's stuck eject, and on a busy Mac the detach took longer. Fixed in `c817790` by giving that step 3 s. Still to do:
- **Run that test 20 times under load** to confirm, then five more full runs under load. Search each log for `error: -[`.
- **Check the other short bounds.** `VaultLockingTests.shortBounds` uses `lockStep: 0.3` and `stopGrace: 0.1`. Any test where a real `diskutil` or `hdiutil` step runs under those bounds has the same weakness. Give real tool steps realistic bounds and keep short bounds only for steps the stand-in fakes.
- **Tests leave disk images attached. This is a real bug in the tests and must be fixed before merge.** After the five runs, two throwaway images were still attached (unmounted): `…/T/vault-locking-<uuid>/sleep-bound/Vault.sparsebundle` and `…/T/vault-locking-<uuid>/out-of-patience/Vault.sparsebundle`. Those tests wedge the eject on purpose and never detach afterwards. Add a teardown, shared by every vault test class, that force-detaches any image whose path is under that test's own temp folder and nothing else, and a check in the suite that none is left: `hdiutil info | grep image-path | grep -c "/T/vault-"` must be 0 after a full run. I detached those two by device after confirming their paths.
- **The message "hdiutil did not finish within 0 seconds"** shows a sub-second bound rounded to 0. Make `ShellError.timedOut` print a sensible number for short bounds.
- Add what you find to issue #39; close it if this accounts for its failure too, or say why it does not.

**1.2 Port the search-handle fix from PR #36** (`log-fix/2026-11-18`). Only this part: in `Sources/Toolbox/Vault/Search/VaultSearchEngine.swift`, `openIndex()` returns the cached index before checking the mount, so after an outside eject it reads a dead SQLite handle and reports "disk I/O error". Check the mount first; on failure close and forget the index and the cached vectors, then throw. Bring #36's test for it from `Tests/ToolboxTests/VaultSearchTests.swift`, adapted to the test rules. Do not bring #36's `VaultModel.swift` change: `main` already has a fuller version from #35. Add one release-note line.

**1.3 Fix the wrong message.** If a password change is running when the app quits, the lock queues behind it, the quit runs out of patience and is refused with "It is taking too long to eject". Say what is true: the password is still being changed, wait for it to finish, then quit. Same for sleep's log line. Test the wording.

**1.4 Look again at one decision.** The door keeps an "another copy is running" check beside the lock file because installed copies up to 0.11.8 take no lock file. Side effect: a mount left by a crash is not recovered while a second idle copy runs. That is acceptable for this release; make sure the README says it and that the check is easy to delete later.

**1.5 Verify.** `swift build --build-tests` (no new warnings), `swiftlint lint --quiet` (0 errors, warnings not above 52), `scripts/check-version-bump.sh` (0.11.8 to 0.11.9), full `swift test` twice with logs kept, `hdiutil info | grep -c image-path` and `mount | grep -c "vault-"` before and after (no test volume left mounted). Then the independent review with `codex-review`: fix what it finds, re-review, stop after three rounds and ask Steven if something serious remains. The first attempt at this rework was abandoned after three rounds kept finding new races, so judge honestly whether the findings are shrinking.

**1.6 Open for merge.** Merge `origin/main` in if it moved. Rewrite this description: why, what, known limits, what was not verified, the exact test lines, review rounds. Mark the PR ready, watch the required checks, read review comments, merge with squash and a Conventional-Commit title. Then close PR #36 with a comment saying its model change landed in #35 and its search-handle fix landed here.

## Step 2: hand test in a built app (scratch vault only)

Build `main` after the merge and launch with `--vault-folder "$(mktemp -d)"` every time. Before launching, ask Steven to confirm his own Toolbox has its vault locked. Take window-only screenshots (`screencapture -l<windowID>`), never the full screen. Try each of these and write down what you saw:

- Cancel a long conversion mid-run (Extract Audio or Trim Audio): no ffmpeg left (`pgrep -x ffmpeg`), no partial file.
- Quit mid-conversion: the app exits, no child process left.
- A real download in Download Video, then cancel one: nothing half-done left in Downloads. This needs the network; ask Steven first.
- Drop a `.txt` and a video together on a batch tool: the "skipped" notice shows.
- Storage Explorer: the page stays responsive while clearing something small and safe that you created yourself. Do not empty Steven's Trash.
- Vault, on the scratch folder: create, unlock, add files, lock; unlock refused over a stray file, with the Show in Finder row; `hdiutil detach -force` on the scratch mount from outside, then the door notice and the not-moved list; quit with the vault open (locks, then quits); quit refused when a file in the scratch vault is held open by another app, and allowed on the second quit; a second copy of the app on the same scratch folder is refused with the "open in another copy" message and ejects nothing.
- Sleep with the scratch vault open is optional: only with Steven's OK, since it sleeps his Mac.

Anything that does not behave as its PR says is a bug: fix it on a branch with a test, PR and merge, before tagging. Report what you could not exercise.

## Step 3: tag once and install

Steven asked for one tag at the very end, and has approved it. When `main`'s CI is green on the final commit: `git tag vX.Y.Z` for `AppVersion.current`, then `git push origin vX.Y.Z` as its own command. Never move or delete a tag on origin.

Then install. In this project "rebuild" means: build the universal app with `scripts/make-app.sh`, back up the current `/Applications/Toolbox.app`, and install the new one. Ask Steven to lock his vault and quit Toolbox first, and do not replace the app while it is running. After the install, ask him to open it, unlock his vault and add one file; then check the log table (`mactoolkit_app_logs`, My Daily Journal project) for new vault errors.

## Step 4: clean up (ask before deleting anything not made in this work)

- Made in this work, safe to remove once merged: worktrees `Toolbox-vault-door` and `Toolbox-repro-vault`, branches `fix/vault-lock-rework` and `fix/vault-lock-and-import` (the latter was never pushed and is reference only), and local `log-fix/2026-11-18` after #36 is closed.
- Older worktrees and branches predate this work (`Toolbox-ai-models`, `Toolbox-extract-frames`, `Toolbox-flaky-power`, `Toolbox-likely-duplicates`, `Toolbox-main-build`, `Toolbox-reveal-frames`, `Toolbox-vault-details`, `Toolbox-version-check`, `Toolbox-versioning`, and local branches such as `feat/vault`, `pr26-bump` and `rook/*`). List which are fully merged into `main` and ask Steven before removing any.
- `REVIEW-2026-11-17.md` and `supabase/.temp/` in the main checkout are Steven's untracked files: leave them.

## Not part of this plan: phase 2

The rest of the review (Swift 6 mode, Scan Document memory, vault and other speed items, accessibility, remaining duplication, a CI script for the prose-only rules, a watch on vendored code, removing comments that are not useful) and three loose ends from this phase are planned in issue #41. Do not start any of it until every step above is done and Steven has seen the report.

## Report to Steven at the end

What merged, the final version and tag, what the hand test showed and what it did not cover, anything left open, and what was cleaned up.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
