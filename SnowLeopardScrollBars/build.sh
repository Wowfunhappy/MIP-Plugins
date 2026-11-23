#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64) from the sources
# and the artwork in build/assets/, which ./extract.sh puts there, and in
# ApertureArt/ (Aperture's full-screen scroll arrows, from an Aperture 3 that
# ran on 10.6; Aperture 3.5 no longer has them).
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
cp -R ApertureArt "$BUNDLE/Contents/Resources/"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m SLCalendar.m SLSkinned.m

echo "Built $BUNDLE"
