#!/usr/bin/env bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 Cross-compiling StationCast NDI Bridge Go binary for Windows (amd64)..."
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -v -ldflags="-s -w -H windowsgui" -o StationCast_NDI_Bridge.exe .

echo "✅ Windows binary created successfully: $DIR/StationCast_NDI_Bridge.exe"
