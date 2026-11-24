#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/checks.sh
source "$ROOT/scripts/lib/checks.sh"
NOTES_SWIFT=Sources/Toolbox/Support/ReleaseNotes.swift

usage() {
  cat <<'USAGE'
Usage: scripts/release.sh vX.Y.Z [--dry-run] [--yes]

Checks and builds Toolbox.app and its DMG on this Mac from the tag vX.Y.Z on origin and publishes the GitHub release.
The tag must be on main, match AppVersion.current at its commit and have no release yet: a release is never replaced.
The tagged commit goes through the same checks as scripts/mac-check.sh (SwiftLint, build, every test) before it is built.

  --dry-run  run every check and the build, leave the DMG and notes in dist/release-X.Y.Z and publish nothing.
             A tag that already has a release is reported instead of stopping the run.
  --yes      publish without asking first.
USAGE
}

TAG=""
DRY_RUN=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes) ASSUME_YES=true ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$TAG" ] || { usage >&2; exit 2; }; TAG="$arg" ;;
  esac
done
[ -n "$TAG" ] || { usage >&2; exit 2; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$TAG is not a vMAJOR.MINOR.PATCH tag."
VERSION="${TAG#v}"
ASSET="Toolbox-$VERSION-macOS-Apple-Silicon.dmg"
OUT="$ROOT/dist/release-$VERSION"

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "Run this on an Apple silicon Mac."
command -v gh > /dev/null || fail "gh is missing. Install it with: brew install gh"
gh auth status > /dev/null 2>&1 || fail "gh is not signed in. Run: gh auth login"
origin_repo="$(github_repo origin)" || fail "origin is not a GitHub repository: $(git remote get-url origin)"
[ -z "${GH_REPO:-}" ] || [ "$GH_REPO" = "$origin_repo" ] ||
  fail "GH_REPO is $GH_REPO but origin is $origin_repo. Unset GH_REPO or release from a checkout of $GH_REPO."
GH_REPO="$origin_repo"
export GH_REPO

step "Checking $TAG on $GH_REPO"
git fetch --quiet --no-tags origin main
git fetch --quiet --no-tags origin "refs/tags/$TAG" 2> /dev/null ||
  fail "origin has no tag $TAG. Tag main and push it first: git tag $TAG origin/main && git push origin $TAG"
COMMIT="$(git rev-parse 'FETCH_HEAD^{commit}')"
local_tag="$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}" || true)"
[ -z "$local_tag" ] || [ "$local_tag" = "$COMMIT" ] || fail "Your local $TAG ($local_tag) is not origin's ($COMMIT)."
git merge-base --is-ancestor "$COMMIT" origin/main || fail "$TAG is not on main."

app_version="$(git show "$COMMIT:$NOTES_SWIFT" | sed -n 's/^ *static let current = "\(.*\)".*/\1/p' | head -1)"
[ "$app_version" = "$VERSION" ] || fail "$TAG points at a commit whose AppVersion.current is $app_version."

released="$(gh release list --limit 1000 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[].tagName')"
if grep -qxF "$TAG" <<< "$released"; then
  $DRY_RUN || fail "A release for $TAG already exists; it is never replaced."
  echo "A release for $TAG already exists, so a real run stops here. The dry run goes on."
fi
highest="$({ grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<< "$released" || true; } | { grep -vxF "$TAG" || true; } | sort -V | tail -1)"
if [ -z "$highest" ] || [ "$(printf '%s\n%s\n' "$highest" "$TAG" | sort -V | tail -1)" = "$TAG" ]; then
  LATEST=true
else
  LATEST=false
fi
echo "$TAG is $COMMIT on main. Highest published release: ${highest:-none}. $TAG becomes Latest: $LATEST."

MAIN="$(git rev-parse origin/main)"
WORK="$(mktemp -d)"
cleanup() {
  git -C "$ROOT" worktree remove --force "$WORK/src" > /dev/null 2>&1 || true
  git -C "$ROOT" worktree remove --force "$WORK/main" > /dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Checking out $TAG and main in temporary worktrees"
git worktree add --quiet --detach "$WORK/src" "$COMMIT"
git worktree add --quiet --detach "$WORK/main" "$MAIN"
reuse_prebuilt "$WORK/src"

run_checks "$WORK/src" "$WORK/tests.log"
test_result_lines "$WORK/tests.log"

step "Building Toolbox.app (scripts/make-app.sh, ad-hoc signed)"
(cd "$WORK/src" && env -u SIGN_IDENTITY -u VERSION -u BUILD -u TOOLS_DIR ARCHS=arm64 scripts/make-app.sh)
signature="$(codesign -dv "$WORK/src/dist/Toolbox.app" 2>&1)"
grep -qx 'Signature=adhoc' <<< "$signature" || fail "Toolbox.app is not ad-hoc signed."
[ -f "$WORK/src/dist/Toolbox.dmg" ] || fail "$TAG's scripts/make-app.sh makes no Toolbox.dmg; only v0.15.1 and later can be released."

step "Naming the download and writing the notes"
rm -rf "$OUT"
mkdir -p "$OUT"
mv "$WORK/src/dist/Toolbox.dmg" "$OUT/$ASSET"
"$WORK/main/.github/scripts/release-body.sh" "$WORK/src/$NOTES_SWIFT" "$VERSION" "${highest#v}" > "$OUT/notes.md"
cat "$OUT/notes.md"
BUILT="$(shasum -a 256 "$OUT/$ASSET" | cut -d' ' -f1)"
echo
echo "$OUT/$ASSET (sha256 $BUILT)"

if $DRY_RUN; then
  echo
  echo "Dry run: nothing was published. A real run would publish \"Toolbox $VERSION\" for $TAG with $ASSET (Latest: $LATEST)."
  exit 0
fi

if ! $ASSUME_YES; then
  [ -t 0 ] || fail "Not asking from a terminal. Pass --yes to publish."
  read -r -p "Publish \"Toolbox $VERSION\" for $TAG on $GH_REPO? [y/N] " answer
  [ "$answer" = y ] || [ "$answer" = Y ] || fail "Not published."
fi

step "Publishing the GitHub release"
gh release create "$TAG" "$OUT/$ASSET" --verify-tag --latest="$LATEST" --title "Toolbox $VERSION" --notes-file "$OUT/notes.md"

step "Checking the published download matches the build"
gh release download "$TAG" --pattern "$ASSET" --dir "$WORK/published"
published="$(shasum -a 256 "$WORK/published/$ASSET" | cut -d' ' -f1)"
[ "$BUILT" = "$published" ] || fail "The published $ASSET ($published) differs from the build ($BUILT)."
echo "Published $ASSET (sha256 $published): $(gh release view "$TAG" --json url --jq .url)"
