#!/bin/bash
# Fails unless this branch bumps the app version and adds release notes for it. Branches that change only files under
# .github/ or files scripts/app-untouched.sh lists (docs, designs) don't change the app and pass without a bump.
# Run by the "Version bumped" job in .github/workflows/ci.yml on every PR and by scripts/mac-check.sh; run it yourself
# before opening one:
#
#   scripts/check-version-bump.sh            # compares with origin/main
#   scripts/check-version-bump.sh <base-ref>
#
# Rules (see AGENTS.md, "Versioning"): unless the app is untouched, AppVersion.current in Sources/Toolbox/Support/ReleaseNotes.swift is
# higher than on the base branch, and the first entry of ReleaseNotes.all is that version with at least one change.
set -euo pipefail

BASE="${1:-origin/main}"
FILE="Sources/Toolbox/Support/ReleaseNotes.swift"
cd "$(dirname "$0")/.."

error() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error file=$FILE::$1"
  else
    echo "error: $1" >&2
  fi
  exit 1
}

git merge-base "$BASE" HEAD > /dev/null 2>&1 || error "No merge base with $BASE; fetch full history (fetch-depth: 0)."
CHANGED="$(git diff --no-renames --name-only -z "$BASE"...HEAD | tr '\0' '\n')"
if [ -n "$CHANGED" ] && { grep -v '^\.github/' <<< "$CHANGED" || true; } | scripts/app-untouched.sh > /dev/null; then
  echo "Only CI files, docs or designs changed ($(wc -l <<< "$CHANGED" | tr -d ' ') file(s)); the app is untouched, so no version bump is needed. OK"
  exit 0
fi

version_in() { sed -n 's/^ *static let current = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' | head -1; }

NEW="$(version_in < "$FILE")"
[ -n "$NEW" ] || error "Could not read AppVersion.current (expected MAJOR.MINOR.PATCH)."

OLD="$(git show "$BASE:$FILE" 2>/dev/null | version_in || true)"
OLD="${OLD:-0.1.1}"   # the last version before ReleaseNotes.swift existed

if [ "$NEW" = "$OLD" ] || [ "$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -1)" != "$NEW" ]; then
  error "Version not bumped: $BASE has $OLD, this branch has $NEW. Raise AppVersion.current (PATCH for fixes, MINOR for new tools/features)."
fi

FIRST="$(sed -n 's/^ *Release(version: "\([^"]*\)".*/\1/p' "$FILE" | head -1)"
if [ "$FIRST" != "$NEW" ]; then
  error "The first entry of ReleaseNotes.all is '$FIRST' but AppVersion.current is '$NEW'. Add a Release for $NEW at the top."
fi

# The new entry must list at least one change: count .init lines between its header and the next Release.
CHANGES="$(awk -v v="$NEW" '
  $0 ~ "Release\\(version: \"" v "\"" { inside=1; next }
  inside && /Release\(version:/ { exit }
  inside && /\.init\(kind:/ { n++ }
  END { print n+0 }' "$FILE")"
if [ "$CHANGES" -lt 1 ]; then
  error "Release $NEW has no changes. Say what was added, improved or fixed."
fi

echo "Version $OLD -> $NEW with $CHANGES release note(s). OK"
