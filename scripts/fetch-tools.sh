#!/bin/bash
# Fetches yt-dlp and builds ffmpeg + ffprobe into build/tools/ for bundling by make-app.sh.
#
#   scripts/fetch-tools.sh                 # universal (arm64 + x86_64)
#   ARCHS=arm64 scripts/fetch-tools.sh     # faster, this Mac only
#
# yt-dlp: official standalone macOS build, checked against the SHA2-256SUMS file of the same release.
# ffmpeg: built from the official source tarball as LGPL-only (no GPL codecs, no Homebrew libraries).
#         Toolbox only remuxes and converts audio, so it needs none of the GPL parts.
set -euo pipefail

YTDLP_VERSION="${YTDLP_VERSION:-2026.10.21}"
FFMPEG_VERSION="${FFMPEG_VERSION:-9.0.2}"
# Checked against Homebrew's formula for the same tarball. When changing FFMPEG_VERSION, update this too.
FFMPEG_SHA256="${FFMPEG_SHA256:-8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e}"
ARCHS="${ARCHS:-arm64 x86_64}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tools"
WORK="$ROOT/build/ffmpeg-work"
mkdir -p "$OUT" "$WORK"

# ---- yt-dlp -----------------------------------------------------------------
echo "==> yt-dlp $YTDLP_VERSION"
base="https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION"
curl -fsSL -o "$WORK/yt-dlp_macos" "$base/yt-dlp_macos"
curl -fsSL -o "$WORK/SHA2-256SUMS" "$base/SHA2-256SUMS"
expected="$(awk '$2 == "yt-dlp_macos" || $2 == "*yt-dlp_macos" {print $1}' "$WORK/SHA2-256SUMS")"
actual="$(shasum -a 256 "$WORK/yt-dlp_macos" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || { echo "yt-dlp checksum mismatch ($expected vs $actual)"; exit 1; }
install -m 755 "$WORK/yt-dlp_macos" "$OUT/yt-dlp"
echo "    checksum ok"

# ---- ffmpeg -----------------------------------------------------------------
echo "==> ffmpeg $FFMPEG_VERSION (LGPL, static, $ARCHS)"
tarball="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
[ -f "$tarball" ] || curl -fsSL -o "$tarball" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
got="$(shasum -a 256 "$tarball" | awk '{print $1}')"
if [ -z "$FFMPEG_SHA256" ]; then
  echo "    WARNING: FFMPEG_SHA256 is not pinned. Computed: $got"
  echo "    Compare it with the signed release on ffmpeg.org, then pin it in this script."
elif [ "$FFMPEG_SHA256" != "$got" ]; then
  echo "ffmpeg tarball checksum mismatch ($FFMPEG_SHA256 vs $got)"; exit 1
fi

build_arch() {
  local arch="$1" src="$WORK/src-$arch" dest="$WORK/install-$arch"
  # Resumable: a finished arch is skipped, an interrupted one continues where make stopped.
  [ -x "$dest/bin/ffmpeg" ] && [ -x "$dest/bin/ffprobe" ] && { echo "    $arch already built"; return; }
  local extra=()
  [ "$arch" != "$(uname -m)" ] && extra=(--enable-cross-compile --arch="$arch" --target-os=darwin --disable-x86asm)
  if [ ! -f "$src/ffbuild/config.mak" ]; then
    rm -rf "$src"; mkdir -p "$src"
    tar -xf "$tarball" -C "$src" --strip-components=1
    ( cd "$src"
      ./configure --prefix="$dest" --cc="clang -arch $arch" \
        --disable-gpl --disable-nonfree --disable-autodetect --disable-network \
        --disable-debug --disable-doc --disable-ffplay --enable-ffprobe \
        --disable-shared --enable-static \
        --enable-zlib --enable-bzlib --enable-iconv --extra-libs=-liconv ${extra[@]+"${extra[@]}"} >"$WORK/configure-$arch.log" )
  fi
  ( cd "$src"
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
    make install >/dev/null )
}

for arch in $ARCHS; do echo "    building $arch"; build_arch "$arch"; done

for tool in ffmpeg ffprobe; do
  inputs=(); for arch in $ARCHS; do inputs+=("$WORK/install-$arch/bin/$tool"); done
  lipo -create "${inputs[@]}" -output "$OUT/$tool"
  chmod 755 "$OUT/$tool"
  # Must not depend on anything outside macOS itself.
  # Library lines are indented; fat files also print an unindented header per architecture.
  if otool -L "$OUT/$tool" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]*(/usr/lib/|/System/)' | grep -q .; then
    echo "$tool links a non-system library:"; otool -L "$OUT/$tool"; exit 1
  fi
done

# ---- smoke test (runs the freshly built tools on this Mac) --------------------
echo "==> smoke test"
T="$WORK/smoke"; rm -rf "$T"; mkdir -p "$T"
"$OUT/ffmpeg" -v error -f lavfi -i testsrc=d=1:s=160x120 -f lavfi -i sine=d=1 -c:v mpeg4 -c:a aac "$T/a.mp4"
"$OUT/ffmpeg" -v error -i "$T/a.mp4" -vn -c:a aac "$T/a.m4a"
"$OUT/ffprobe" -v error -show_entries stream=codec_name -of csv=p=0 "$T/a.m4a" | grep -q aac
"$OUT/ffmpeg" -version | grep -q -- '--disable-gpl'
"$OUT/yt-dlp" --version

echo "==> done: $OUT"
ls -lh "$OUT"
