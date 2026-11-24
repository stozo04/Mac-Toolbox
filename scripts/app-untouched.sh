#!/bin/bash
# Reads changed paths on stdin, one per line. Exits 0 when none of them can change Toolbox.app: docs, designs
# and the Dependabot config. Otherwise prints the first path that can and exits 1.
# Shared by scripts/mac-check.sh (whether there is anything to build and test) and by
# scripts/check-version-bump.sh (whether a version bump is needed), so the two can never disagree.
set -euo pipefail

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  case "$path" in
    THIRD_PARTY_NOTICES.md) echo "$path"; exit 1 ;;   # copied into Toolbox.app by scripts/make-app.sh
    *.md | features/* | images/* | .github/dependabot.yml) ;;
    *) echo "$path"; exit 1 ;;
  esac
done
exit 0
