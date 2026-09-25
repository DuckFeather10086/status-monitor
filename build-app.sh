#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/StatusMonitor.app"

cd "$ROOT"
swift build -c release

# Stop only the copy being rebuilt, after compilation succeeds.
# Replacing a signed executable underneath a running process can invalidate it.
while IFS= read -r monitor_pid; do
    [[ -n "$monitor_pid" ]] || continue
    monitor_command="$(ps -p "$monitor_pid" -o comm= 2>/dev/null || true)"
    if [[ "$monitor_command" == "$APP_DIR/Contents/MacOS/StatusMonitor" ]]; then
        kill -TERM "$monitor_pid" 2>/dev/null || true
    fi
done < <(pgrep -x StatusMonitor || true)

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/StatusMonitor" "$APP_DIR/Contents/MacOS/StatusMonitor"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP_DIR"

echo "Built: $APP_DIR"
