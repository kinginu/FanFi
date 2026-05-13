#!/bin/bash
# Assemble FanFiApp.app from the SwiftPM-built binaries.
#
# Produces ./FanFiApp.app with this layout:
#   FanFiApp.app/
#     Contents/
#       Info.plist
#       MacOS/
#         FanFiApp        (menu bar app)
#         FanFiHelper     (privileged daemon)
#       Library/
#         LaunchDaemons/
#           com.fanfi.helper.plist
#
# Ad-hoc codesigns the result (`codesign -s -`). That's enough for local dev
# of SMAppService.daemon — real distribution still needs a Developer ID cert.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/FanFiApp.app"

CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$ROOT/.build/$CONFIG"
APP_BIN="$BIN_DIR/FanFiApp"
HELPER_BIN="$BIN_DIR/FanFiHelper"

if [ ! -x "$APP_BIN" ] || [ ! -x "$HELPER_BIN" ]; then
    echo "error: missing $APP_BIN or $HELPER_BIN" >&2
    exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchDaemons"

cp "$APP_BIN" "$APP/Contents/MacOS/FanFiApp"
cp "$HELPER_BIN" "$APP/Contents/MacOS/FanFiHelper"
cp "$ROOT/Resources/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/bundle/com.fanfi.helper.plist" \
   "$APP/Contents/Library/LaunchDaemons/com.fanfi.helper.plist"

chmod 755 "$APP/Contents/MacOS/FanFiApp" "$APP/Contents/MacOS/FanFiHelper"

echo "==> Ad-hoc codesign (identifiers must match plist Label / bundle ID)"
# Sign the helper FIRST with an explicit identifier matching the plist's
# Label. Without --identifier the ad-hoc signature derives the identifier
# from the binary hash, which SMAppService cannot reconcile with the
# daemon plist → service.status = .notFound.
codesign --force --sign - \
    --identifier com.fanfi.helper \
    "$APP/Contents/MacOS/FanFiHelper" >/dev/null

# Then sign the outer bundle. --deep would re-sign the helper without our
# identifier override, so we skip --deep here.
codesign --force --sign - \
    --identifier com.fanfi.app \
    "$APP" >/dev/null

echo "    bundle:"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Format|Signature)' | sed 's/^/      /'
echo "    helper:"
codesign -dv "$APP/Contents/MacOS/FanFiHelper" 2>&1 | grep -E '^(Identifier|Format|Signature)' | sed 's/^/      /'
codesign --verify --verbose=1 "$APP" 2>&1 | head -3

echo
echo "Built: $APP"
echo
echo "Next: open the bundle (or launch directly):"
echo "  open $APP"
echo "  # Approve the helper in System Settings > General > Login Items & Extensions"
