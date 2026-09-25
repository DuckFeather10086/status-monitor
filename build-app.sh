#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/StatusMonitor.app"

cd "$ROOT"
swift build -c release

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/StatusMonitor" "$APP_DIR/Contents/MacOS/StatusMonitor"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"

echo "Built: $APP_DIR"
