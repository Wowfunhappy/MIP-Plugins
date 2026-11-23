#!/bin/bash
# Builds build/SnowLeopardWindows.bundle (i386 + x86_64).
# To install, copy it into /usr/share/mip/Bundles/ and relaunch your apps.
#
# The title bar buttons are Snow Leopard's own images, which are not part of
# this repository. They are extracted from Mac OS X 10.6's CoreUI ArtFile.bin:
#   ./build.sh /path/to/ArtFile.bin
# or set SL_ARTFILE. Without either, the copy on a mounted Snow Leopard
# install DVD is used.
#
# For Retina displays, the buttons are also rendered at 2x from 10.6's
# resolution-independent recipes (UI.bundle, next to ArtFile.bin) with
# Mavericks' own renderer; see render_hidpi.m. That step needs OS X 10.9.
# Without UI.bundle the plugin is built with 1x buttons only.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardWindows
BUNDLE="build/$NAME.bundle"
ARTFILE="${1:-${SL_ARTFILE:-/Volumes/Mac OS X Install DVD/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources/ArtFile.bin}}"

if [ ! -f "$ARTFILE" ]; then
    echo "Snow Leopard's ArtFile.bin not found at: $ARTFILE" >&2
    echo "Mount a Mac OS X 10.6 install DVD, or pass the path to 10.6's" >&2
    echo "CoreUI.framework/Versions/A/Resources/ArtFile.bin as an argument." >&2
    exit 1
fi

UIBUNDLE="$(dirname "$ARTFILE")/UI.bundle"

rm -rf "$BUNDLE" build/tools
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" build/tools
cp Info.plist "$BUNDLE/Contents/Info.plist"
python extract_art.py "$ARTFILE" "$BUNDLE/Contents/Resources/SLWindowArt.bin" build/tools/tags.plist

if [ -d "$UIBUNDLE/Contents/Recipes" ]; then
    clang -arch x86_64 -Os -Wall -framework Cocoa -o build/tools/render_hidpi render_hidpi.m
    clang -arch x86_64 -Os -Wall -dynamiclib -framework ApplicationServices \
        -o build/tools/render_hidpi_cache.dylib render_hidpi_cache.c
    DYLD_INSERT_LIBRARIES="$PWD/build/tools/render_hidpi_cache.dylib" build/tools/render_hidpi \
        "$UIBUNDLE" build/tools/tags.plist "$BUNDLE/Contents/Resources/SLWindowArt.bin" \
        "$BUNDLE/Contents/Resources/SLWindowArt@2x.bin"
else
    echo "No UI.bundle next to ArtFile.bin: building with 1x buttons only." >&2
fi

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLWindows.m

echo "Built $BUNDLE"
