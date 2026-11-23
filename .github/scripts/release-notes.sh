#!/bin/bash
# Prints the release notes of a GitHub release as Markdown, read from ReleaseNotes.swift: every entry newer than
# <since> up to and including <version>, newest first, so versions that never got a release of their own are not lost.
# Fails when <version> has no entry or an entry has no changes.
#
#   .github/scripts/release-notes.sh <ReleaseNotes.swift> <version> [<since>]
#
# Run by release-body.sh, which wraps these entries in the whole body of a release.
set -euo pipefail

NOTES_FILE="$1"
VERSION="$2"
SINCE="${3:-}"

newer_than() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

ALL_VERSIONS="$(sed -n 's/^ *Release(version: "\([^"]*\)".*/\1/p' "$NOTES_FILE")"
grep -qxF "$VERSION" <<< "$ALL_VERSIONS" || { echo "::error file=$NOTES_FILE::No release notes for $VERSION." >&2; exit 1; }

INCLUDED=""
while IFS= read -r candidate; do
  if [ "$candidate" = "$VERSION" ] || { [ -n "$SINCE" ] && newer_than "$VERSION" "$candidate" && newer_than "$candidate" "$SINCE"; }; then
    INCLUDED+="$candidate "
  fi
done <<< "$ALL_VERSIONS"

awk -v included=" $INCLUDED" '
  BEGIN { kinds["new"] = "New"; kinds["improved"] = "Improved"; kinds["fixed"] = "Fixed"; kinds["removed"] = "Removed" }
  function finish() {
    if (current != "" && changes == 0) { print "::error::Release " current " has no changes." > "/dev/stderr"; failed = 1 }
  }
  /^ *Release\(version: "/ {
    finish()
    match($0, /"[^"]*"/); version = substr($0, RSTART + 1, RLENGTH - 2)
    current = (index(included, " " version " ") > 0) ? version : ""
    changes = 0
    if (current != "") { if (printed) print ""; print "### " current; printed = 1 }
    next
  }
  current != "" && /\.init\(kind: \./ {
    match($0, /kind: \.[a-z]+/); kind = kinds[substr($0, RSTART + 7, RLENGTH - 7)]
    text = $0
    sub(/^[^"]*"/, "", text); sub(/"\),? *$/, "", text)
    gsub(/\\"/, "\"", text); gsub(/\\\\/, "\\", text)
    print "- **" kind "** " text
    changes++
  }
  END { finish(); exit failed }
' "$NOTES_FILE"
