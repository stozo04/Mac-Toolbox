#!/bin/bash
set -euo pipefail

CONTEXT="Mac checks"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'USAGE'
Usage: scripts/mac-check.sh [--report] [--full]

Runs on this Mac every check GitHub's macOS runners used to run: SwiftLint (errors fail, swift-format only reports),
swift build --build-tests and swift test, then the Toolbox.app and DMG build (scripts/make-app.sh).

  --report  also mark the commit on GitHub with the "Mac checks" status that main requires. Needs gh signed in,
            a clean working tree and a branch whose remote is at HEAD.
  --full    build and test even when only docs, designs or GitHub files changed.
USAGE
}

REPORT=false
FULL=false
for arg in "$@"; do
  case "$arg" in
    --report) REPORT=true ;;
    --full) FULL=true ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fail() {
  echo "error: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "Run this on an Apple silicon Mac."

SHA="$(git rev-parse HEAD)"
STARTED=false

if $REPORT; then
  command -v gh > /dev/null || fail "gh is missing. Install it with: brew install gh"
  gh auth status > /dev/null 2>&1 || fail "gh is not signed in. Run: gh auth login"
  [ -z "$(git status --porcelain)" ] || fail "The working tree has changes. Commit or stash them so the status describes a pushed commit."
  branch="$(git symbolic-ref --quiet --short HEAD)" || fail "HEAD is detached. Check out the pull request's branch."
  [ "$branch" != main ] || fail "--report marks a pull request's branch, not main."
  remote="$(git config "branch.$branch.remote" || true)"
  merge_ref="$(git config "branch.$branch.merge" || true)"
  [ -n "$remote" ] && [ -n "$merge_ref" ] || fail "$branch has no upstream. Push it with: git push -u origin $branch"
  git fetch --quiet --no-tags "$remote" "$merge_ref" || fail "Could not fetch $merge_ref from $remote."
  [ "$(git rev-parse FETCH_HEAD)" = "$SHA" ] || fail "$remote's $branch is not at HEAD ($SHA). Push or pull first."
  REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

post_status() {
  $REPORT || return 0
  gh api --silent --method POST "repos/$REPO/statuses/$SHA" -f state="$1" -f context="$CONTEXT" -f description="$2"
  echo "Marked $SHA on $REPO: $CONTEXT $1"
}

finish() {
  local code=$?
  if [ "$code" -ne 0 ] && $STARTED; then
    post_status failure "Failed on a Mac. Run scripts/mac-check.sh to see why." || true
  fi
  exit "$code"
}
trap finish EXIT

post_status pending "Running scripts/mac-check.sh on a Mac"
STARTED=true

git fetch --quiet --no-tags origin main
base="$(git merge-base origin/main HEAD)"
changed="$({ git diff --no-renames --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)"

app=true
if ! $FULL && [ -n "$changed" ] && { grep -v '^\.github/' <<< "$changed" || true; } | scripts/app-untouched.sh > /dev/null; then
  app=false
fi

if [ "$(git rev-list --count origin/main..HEAD)" -gt 0 ]; then
  step "Version bumped"
  scripts/check-version-bump.sh origin/main
fi

if ! $app; then
  echo
  echo "Only docs, designs or GitHub files changed, so there is nothing to build. Run with --full to build anyway."
  post_status success "Only docs, designs or GitHub files changed"
  STARTED=false
  exit 0
fi

command -v swiftlint > /dev/null || fail "SwiftLint is missing. Install it with: brew install swiftlint"

step "SwiftLint"
swiftlint lint --quiet

step "swift-format (reports only)"
findings="$(xcrun swift-format lint --recursive --parallel Sources/Toolbox Tests 2>&1 | grep -c ': warning:' || true)"
echo "swift-format findings: $findings"

step "llama.cpp (Vault search)"
scripts/build-llama.sh

step "yt-dlp, ffmpeg and ffprobe"
tools_stamp="$(shasum -a 256 scripts/fetch-tools.sh | cut -c1-64) arm64"
if [ "$(cat build/tools/STAMP 2> /dev/null)" = "$tools_stamp" ] && [ -x build/tools/yt-dlp ] && [ -x build/tools/ffmpeg ] && [ -x build/tools/ffprobe ]; then
  echo "Up to date in build/tools."
else
  ARCHS=arm64 scripts/fetch-tools.sh
  echo "$tools_stamp" > build/tools/STAMP
fi

step "swift build --build-tests"
swift build --build-tests

step "swift test"
test_log="$(mktemp)"
CI=true swift test --skip-build 2>&1 | tee "$test_log"
test_result="$(grep -E 'Executed [0-9]+ tests?, with|Test run with [0-9]+ tests?' "$test_log" | tail -2 || true)"
rm -f "$test_log"

step "Toolbox.app and DMG (scripts/make-app.sh)"
env -u SIGN_IDENTITY ARCHS=arm64 scripts/make-app.sh
[ -f dist/Toolbox.dmg ] || fail "scripts/make-app.sh made no dist/Toolbox.dmg."

if $REPORT; then
  [ "$(git rev-parse HEAD)" = "$SHA" ] || fail "HEAD moved while the checks ran."
  [ -z "$(git status --porcelain)" ] || fail "The checks changed tracked files: $(git status --porcelain | head -3 | tr '\n' ' ')"
fi

post_status success "Lint, build, tests and app build passed on a Mac"
STARTED=false

echo
echo "All Mac checks passed for $SHA."
[ -z "$test_result" ] || echo "$test_result"
