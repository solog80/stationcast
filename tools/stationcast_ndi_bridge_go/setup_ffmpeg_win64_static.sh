#!/usr/bin/env bash
set -e

# Builds a minimal, static FFmpeg (H.264 + Opus decoders, DXVA2/D3D11VA GPU decode)
# for x86_64-w64-mingw32 and installs it into third_party/ffmpeg-win64-static.
# This lets build_win.sh produce a single self-contained .exe with no DLLs.
#
# Requires: brew install mingw-w64   (and make, curl, tar on PATH)

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "❌ x86_64-w64-mingw32-gcc not found. Install with: brew install mingw-w64"
  exit 1
fi

FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
DEST="$DIR/third_party/ffmpeg-win64-static"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "⬇️  Downloading FFmpeg $FFMPEG_VERSION source..."
curl -L -o "$TMP/ffmpeg.tar.xz" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
tar -xf "$TMP/ffmpeg.tar.xz" -C "$TMP"
SRC="$TMP/ffmpeg-${FFMPEG_VERSION}"

echo "⚙️  Configuring minimal static build (h264 + opus decode, DXVA2/D3D11VA hwaccel)..."
cd "$SRC"
./configure \
  --prefix="$TMP/out" \
  --cross-prefix=x86_64-w64-mingw32- \
  --target-os=mingw32 --arch=x86_64 \
  --enable-static --disable-shared \
  --disable-programs --disable-doc --disable-avdevice --disable-avfilter --disable-postproc \
  --disable-network --disable-autodetect \
  --disable-everything \
  --enable-decoder=h264,opus \
  --enable-parser=h264 \
  --enable-hwaccel=h264_d3d11va,h264_d3d11va2,h264_dxva2 \
  --enable-d3d11va --enable-dxva2 \
  --disable-x86asm >/dev/null

echo "🔨 Compiling FFmpeg (this takes a few minutes)..."
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null

echo "📦 Installing static SDK to $DEST..."
rm -rf "$DEST"
mkdir -p "$DEST/include" "$DEST/lib"
cp -R "$TMP/out/include/." "$DEST/include/"
cp "$TMP/out/lib/libavcodec.a" "$TMP/out/lib/libavutil.a" \
   "$TMP/out/lib/libswscale.a" "$TMP/out/lib/libswresample.a" "$DEST/lib/"

echo "✅ Static FFmpeg SDK ready: $DEST"
echo "   Now run ./build_win.sh"
