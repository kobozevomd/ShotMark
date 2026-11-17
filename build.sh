#!/bin/bash
# Builds ShotMark.app into ./build.
#   --install  copy it to /Applications and launch
#   --zip      also pack build/ShotMark-<version>.zip for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ShotMark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple Silicon + Intel.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$ARCH-apple-macos14.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework AppKit -framework ScreenCaptureKit -framework Carbon -framework ServiceManagement -framework Vision \
    Sources/*.swift \
    -o "build/ShotMark-$ARCH"
done
lipo -create build/ShotMark-arm64 build/ShotMark-x86_64 -output "$APP/Contents/MacOS/ShotMark"
rm build/ShotMark-arm64 build/ShotMark-x86_64

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - --identifier ru.kobozev.ShotMark "$APP"
echo "Built $APP"

if [ "${1:-}" = "--zip" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
  ditto -c -k --keepParent "$APP" "build/ShotMark-$VERSION.zip"
  echo "Packed build/ShotMark-$VERSION.zip"
fi

if [ "${1:-}" = "--install" ]; then
  pkill -x ShotMark || true
  rm -rf /Applications/ShotMark.app
  cp -R "$APP" /Applications/ShotMark.app
  # Don't leave a second copy around: macOS would list it as another ShotMark.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
  rm -rf build
  open /Applications/ShotMark.app
  echo "Installed to /Applications/ShotMark.app"
fi
