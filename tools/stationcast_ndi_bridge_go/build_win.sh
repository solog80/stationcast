#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

# MinGW cross-compiler is required for CGO (FFmpeg H.264 decoder).
if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "❌ x86_64-w64-mingw32-gcc not found. Install with: brew install mingw-w64"
  exit 1
fi

# Windows FFmpeg static SDK (headers + static .a libs). No runtime DLLs needed.
# Override with FFMPEG_WIN64_STATIC_DIR if you keep it elsewhere.
FFROOT="${FFMPEG_WIN64_STATIC_DIR:-$DIR/third_party/ffmpeg-win64-static}"
if [ ! -f "$FFROOT/include/libavcodec/avcodec.h" ] || [ ! -f "$FFROOT/lib/libavcodec.a" ]; then
  echo "❌ Windows static FFmpeg SDK not found at: $FFROOT"
  echo "   Run ./setup_ffmpeg_win64_static.sh to build it, or set FFMPEG_WIN64_STATIC_DIR."
  exit 1
fi

echo "🔨 Cross-compiling StationCast NDI Bridge for Windows (amd64, static FFmpeg H.264)..."
CC=x86_64-w64-mingw32-gcc \
CGO_ENABLED=1 \
GOOS=windows \
GOARCH=amd64 \
CGO_CFLAGS="-I$FFROOT/include" \
CGO_LDFLAGS="-L$FFROOT/lib -lavcodec -lswscale -lswresample -lavutil -lbcrypt -lws2_32 -lsecur32 -lole32 -lshell32 -luser32 -lgdi32 -ladvapi32 -ld3d11 -ldxva2 -luuid -lstrmiids -lksuser" \
go build -v -ldflags="-s -w -H windowsgui -extldflags=-static" -o StationCast_NDI_Bridge.exe .

echo "✅ Windows binary created: $DIR/StationCast_NDI_Bridge.exe (self-contained, no DLLs)"
