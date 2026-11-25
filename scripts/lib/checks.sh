#!/bin/bash
# Sourced by scripts/mac-check.sh and scripts/release.sh: the checks every commit and every release goes through,
# run against any checkout of the app (a release checks the tagged commit in a temporary worktree, whose own scripts
# may predate this file).

fail() {
  echo "error: $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

github_repo() {
  local url
  url="$(git remote get-url "$1" 2> /dev/null)" || return 1
  url="${url%.git}"
  case "$url" in
    https://github.com/*/*) echo "${url#https://github.com/}" ;;
    git@github.com:*/*) echo "${url#git@github.com:}" ;;
    ssh://git@github.com/*/*) echo "${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
}

main_worktree() {
  git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p'
}

tools_stamp() {
  echo "$(shasum -a 256 "$1/scripts/fetch-tools.sh" | cut -c1-64) arm64"
}

tools_ready() {
  [ "$(cat "$1/build/tools/STAMP" 2> /dev/null)" = "$(tools_stamp "$1")" ] &&
    [ -x "$1/build/tools/yt-dlp" ] && [ -x "$1/build/tools/ffmpeg" ] && [ -x "$1/build/tools/ffprobe" ]
}

reuse_prebuilt() {
  local root="$1" prebuilt
  prebuilt="$(main_worktree "$root")"
  [ -n "$prebuilt" ] && [ "$prebuilt" != "$root" ] || return 0
  if [ ! -f "$root/Vendor/llama/lib/libllamacpp.a" ] && [ -f "$prebuilt/Vendor/llama/lib/libllamacpp.a" ]; then
    echo "Copying llama.cpp from $prebuilt (scripts/build-llama.sh rebuilds it if its stamp is not this checkout's)."
    mkdir -p "$root/Vendor"
    cp -Rc "$prebuilt/Vendor/llama" "$root/Vendor/llama"
  fi
  if ! tools_ready "$root" && [ "$(cat "$prebuilt/build/tools/STAMP" 2> /dev/null)" = "$(tools_stamp "$root")" ]; then
    echo "Copying yt-dlp, ffmpeg and ffprobe from $prebuilt/build/tools."
    rm -rf "$root/build/tools"
    mkdir -p "$root/build"
    cp -Rc "$prebuilt/build/tools" "$root/build/tools"
  fi
}

run_checks() {
  local root="$1" test_log="$2"
  command -v swiftlint > /dev/null || fail "SwiftLint is missing. Install it with: brew install swiftlint"
  (
    cd "$root" || exit 1

    step "SwiftLint"
    swiftlint lint --quiet

    step "swift-format (reports only)"
    local findings
    findings="$(xcrun swift-format lint --recursive --parallel Sources/Toolbox Tests 2>&1 | grep -c ': warning:' || true)"
    echo "swift-format findings: $findings"

    step "llama.cpp (Vault search)"
    scripts/build-llama.sh

    step "yt-dlp, ffmpeg and ffprobe"
    if tools_ready "$root"; then
      echo "Up to date in build/tools."
    else
      ARCHS=arm64 scripts/fetch-tools.sh
      tools_stamp "$root" > build/tools/STAMP
    fi

    step "swift build --build-tests"
    swift build --build-tests

    step "swift test"
    CI=true swift test --skip-build 2>&1 | tee "$test_log"
  )
}

build_app() {
  (cd "$1" && env -u VERSION -u BUILD -u TOOLS_DIR SIGN_IDENTITY=- ARCHS=arm64 scripts/make-app.sh)
}

test_result_lines() {
  grep -E 'Executed [0-9]+ tests?, with|Test run with [0-9]+ tests?' "$1" | tail -2 || true
}

test_counts() {
  grep -E 'Executed [0-9]+ tests?, with' "$1" | tail -1 |
    sed -nE 's/.*Executed ([0-9]+) tests?, with (([0-9]+) tests? skipped and )?([0-9]+) failures?.*/\1 tests, \3 skipped, \4 failures/p' |
    sed 's/,  skipped,/, 0 skipped,/'
}
