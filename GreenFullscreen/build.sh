#!/bin/bash
# Builds build/GreenFullscreen.bundle (i386 + x86_64, for garbage-collected apps too).
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch your
# apps.
set -e
cd "$(dirname "$0")"

NAME=GreenFullscreen
BUNDLE="build/$NAME.bundle"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"
mkdir -p "$BUNDLE/Contents/Resources"
cp Resources/*.png "$BUNDLE/Contents/Resources/"     # Yosemite's full-screen arrows (GreenFullscreen.m)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y.%m.%d)" "$BUNDLE/Contents/Info.plist" > /dev/null
chmod 644 "$BUNDLE/Contents/Info.plist"

# It loads into every app, garbage-collected ones included: built for GC too
# (-fobjc-gc), with the clang that ../tools/gc-clang.sh provides.
CLANG=$(../tools/gc-clang.sh)
"$CLANG" -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 -isysroot "$(xcrun --show-sdk-path)" \
    -fobjc-gc -Os -Wall -Wno-deprecated-declarations -fno-objc-arc -I../ZKSwizzle \
    -framework Cocoa -framework ApplicationServices -framework Carbon \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    GreenFullscreen.m ../ZKSwizzle/ZKSwizzle.m

echo "Built $BUNDLE"
