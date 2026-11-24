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

# The bundle's main executable: no AppKit (SLCarbon.m), so it can go into
# Carbon apps that have none. It loads SnowLeopardScrollBars-AppKit into apps
# that have AppKit.
FLAGS="-arch i386 -arch x86_64 -mmacosx-version-min=10.9 -Os -Wall -Wno-deprecated-declarations -fno-objc-arc -fvisibility=hidden"
clang -bundle $FLAGS -framework Foundation -framework Carbon \
    -o "$BUNDLE/Contents/MacOS/$NAME" SLCarbon.m
clang -bundle $FLAGS -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME-AppKit" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m SLCalendar.m SLSkinned.m SLPrefPane.m
if otool -L "$BUNDLE/Contents/MacOS/$NAME" | grep -q AppKit.framework; then
    echo "$NAME must not link AppKit." >&2
    exit 1
fi

echo "Built $BUNDLE"
