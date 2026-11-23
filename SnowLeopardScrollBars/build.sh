#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64).
# To install, copy it into /usr/share/mip/Bundles/ and relaunch your apps.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardScrollBars
BUNDLE="build/$NAME.bundle"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m

echo "Built $BUNDLE"

