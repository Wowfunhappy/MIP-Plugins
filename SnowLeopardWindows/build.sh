#!/bin/bash
# Builds build/SnowLeopardWindows.bundle (i386 + x86_64) from the sources and
# the Snow Leopard artwork in build/assets/, which ./extract.sh puts there.
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch your
# apps.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardWindows
BUNDLE="build/$NAME.bundle"
ASSETS=build/assets

for asset in SLWindowArt.bin SLWindowArt@2x.bin SLTabArt SLQuickTimeArt; do
    if [ ! -e "$ASSETS/$asset" ]; then
        echo "Not found: $ASSETS/$asset - run ./extract.sh first." >&2
        exit 1
    fi
done

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp -R "$ASSETS/SLWindowArt.bin" "$ASSETS/SLWindowArt@2x.bin" "$ASSETS/SLTabArt" "$ASSETS/SLQuickTimeArt" \
    "$BUNDLE/Contents/Resources/"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework Carbon -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLWindows.m

echo "Built $BUNDLE"
