#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64) from the sources
# and the artwork and text in build/assets/, which ./extract.sh puts there, and in
# ApertureArt/ (Aperture's full-screen scroll arrows, from an Aperture 3 that
# ran on 10.6; Aperture 3.5 no longer has them).
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch your
# apps.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardScrollBars
BUNDLE="build/$NAME.bundle"
ASSETS=build/assets

for asset in SLScrollArt@2x.bin ArrowStrings/English.lproj/SLScrollArrows.strings; do
    if [ ! -e "$ASSETS/$asset" ]; then
        echo "Not found: $ASSETS/$asset - run ./extract.sh first." >&2
        exit 1
    fi
done

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp "$ASSETS/SLScrollArt@2x.bin" "$BUNDLE/Contents/Resources/"
cp -R "$ASSETS/ArrowStrings/"*.lproj "$BUNDLE/Contents/Resources/"
cp -R ApertureArt "$BUNDLE/Contents/Resources/"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore -framework Carbon \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m SLCalendar.m SLSkinned.m SLPrefPane.m SLCarbon.m

# Marked as supporting garbage collection, so it loads into GC apps too
# (SLKeep, in SLScrollBars.h, explains what that asks of the code).
MARKGC=../tools/build/markgc
if [ ! -x "$MARKGC" ] || [ ../tools/markgc.cpp -nt "$MARKGC" ]; then
    mkdir -p ../tools/build
    clang++ -std=c++11 -o "$MARKGC" ../tools/markgc.cpp
fi
"$MARKGC" "$BUNDLE/Contents/MacOS/$NAME" > /dev/null

echo "Built $BUNDLE"
