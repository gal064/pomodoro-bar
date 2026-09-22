#!/bin/bash
# Build PomodoroBar.app from Swift sources, ad-hoc sign it, and install it
# into /Applications. Pass --no-install to only build into ./build.
set -euo pipefail
cd "$(dirname "$0")"

ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/PomodoroBar.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

rm -rf "$BUILD"
mkdir -p "$MACOS" "$RES"

echo "Compiling..."
swiftc -O \
  Sources/main.swift \
  Sources/AppDelegate.swift \
  Sources/TimerModel.swift \
  Sources/PopoverViewController.swift \
  Sources/RingView.swift \
  -o "$MACOS/PomodoroBar" \
  -framework Cocoa \
  -framework QuartzCore \
  -framework UserNotifications \
  -framework ServiceManagement \
  -framework AVFoundation

cp Info.plist "$CONTENTS/Info.plist"

# Best-effort app icon rendered from the tomato emoji.
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
if swiftc -O Tools/makeicon.swift -o "$BUILD/makeicon" 2>/dev/null \
   && "$BUILD/makeicon" "$ICONSET"; then
  iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" 2>/dev/null || echo "  (icon skipped)"
fi

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Built: $APP"

if [ "${1:-}" = "--no-install" ]; then
  exit 0
fi

DEST="/Applications/PomodoroBar.app"
echo "Installing to /Applications..."
pkill -x PomodoroBar 2>/dev/null || true
sleep 0.3
if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" "$DEST" 2>/dev/null; then
  echo "Installed: $DEST"
  echo "Launch it with:  open -a PomodoroBar"
else
  echo "Could not write to /Applications automatically."
  echo "Drag $APP into /Applications manually, then launch it."
fi
