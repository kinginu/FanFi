#!/bin/bash
# Dev install for FanFiHelper. Phase 2 Session 1: manual launchd plist.
# Phase 3 will replace this with SMAppService inside a notarised app bundle.
set -euo pipefail

PLIST_SRC="$(cd "$(dirname "$0")" && pwd)/com.fanfi.helper.plist"
PLIST_DST="/Library/LaunchDaemons/com.fanfi.helper.plist"

if [ ! -f "$PLIST_SRC" ]; then
    echo "missing $PLIST_SRC" >&2
    exit 1
fi

# Make sure the binary referenced in the plist actually exists.
BIN=$(/usr/libexec/PlistBuddy -c "Print ProgramArguments:0" "$PLIST_SRC")
if [ ! -x "$BIN" ]; then
    echo "binary not found or not executable: $BIN" >&2
    echo "build with: swift build -c release" >&2
    exit 1
fi

echo "Installing $PLIST_DST -> $BIN"

sudo cp "$PLIST_SRC" "$PLIST_DST"
sudo chown root:wheel "$PLIST_DST"
sudo chmod 644 "$PLIST_DST"

# Idempotent: bootout existing service if present, then bootstrap.
if sudo launchctl print system/com.fanfi.helper >/dev/null 2>&1; then
    echo "Re-bootstrapping (existing service found)"
    sudo launchctl bootout system "$PLIST_DST" 2>/dev/null || true
fi
sudo launchctl bootstrap system "$PLIST_DST"

echo
echo "Installed. Helper will start on first XPC connection."
echo "Logs: /tmp/fanfi-helper.log"
echo "Test:  sudo launchctl print system/com.fanfi.helper | head -20"
