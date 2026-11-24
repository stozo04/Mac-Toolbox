#!/bin/bash
# Prints the whole body of a GitHub release as Markdown: how to install the download, then what's new (the entries
# release-notes.sh reads from ReleaseNotes.swift), then who built it and the licenses.
#
#   .github/scripts/release-body.sh <ReleaseNotes.swift> <version> [<since>]
#
# Run by scripts/release.sh (the notes of a release) and ci.yml (proves the body still renders).
set -euo pipefail

NOTES_FILE="$1"
VERSION="$2"
SINCE="${3:-}"
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
DMG="Toolbox-$VERSION-macOS-Apple-Silicon.dmg"

whats_new="$("$SCRIPTS/release-notes.sh" "$NOTES_FILE" "$VERSION" "$SINCE")"
built_by="Built on an Apple silicon Mac from the tagged commit."

cat <<BODY
## Install

Download **$DMG** below. It is for Macs with Apple silicon (M1 or later) running macOS 14 or later.

1. Open the DMG and drag **Toolbox** into **Applications**.
2. Open Toolbox from Applications. This build is ad-hoc signed and not notarized by Apple, so macOS blocks it the first time. Open **System Settings > Privacy & Security** and click **Open Anyway**. Apple's steps:

   https://support.apple.com/guide/mac-help/mh40616/mac

   Or run this in Terminal instead, then open Toolbox:

   \`\`\`
   xattr -dr com.apple.quarantine /Applications/Toolbox.app
   \`\`\`

macOS asks once for each version you download.

## What's new

$whats_new

The full history is inside the app: click the version number in the bottom-right corner.

---

$built_by Includes yt-dlp (Unlicense) and an LGPL build of FFmpeg; see \`Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md\`. Only download videos you own or have permission to save.
BODY
