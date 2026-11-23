#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64) from the sources
# and the artwork in build/assets/, which ./extract.sh puts there.
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch your
# apps.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardScrollBars
BUNDLE="build/$NAME.bundle"
ASSETS=build/assets

if [ ! -e "$ASSETS/SLScrollArt@2x.bin" ]; then
    echo "Not found: $ASSETS/SLScrollArt@2x.bin - run ./extract.sh first." >&2
    exit 1
fi

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$ASSETS/SLScrollArt@2x.bin" "$BUNDLE/Contents/Resources/"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m SLCalendar.m SLSkinned.m

echo "Built $BUNDLE"
