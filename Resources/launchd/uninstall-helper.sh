#!/bin/bash
set -euo pipefail

PLIST_DST="/Library/LaunchDaemons/com.fanfi.helper.plist"

if sudo launchctl print system/com.fanfi.helper >/dev/null 2>&1; then
    sudo launchctl bootout system "$PLIST_DST" 2>/dev/null || true
fi

if [ -f "$PLIST_DST" ]; then
    sudo rm "$PLIST_DST"
    echo "Removed $PLIST_DST"
else
    echo "Already absent: $PLIST_DST"
fi
