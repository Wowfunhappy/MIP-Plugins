#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64).
# To install, copy it into /usr/share/mip/Bundles/ and relaunch your apps.
#
# The scroll bar art is read at run time from the system (Extras2.rsrc, the
# same file 10.6 used). On Retina displays it is drawn scaled up, as 10.6 did,
# except that the arrow buttons' triangles are redrawn sharp: hidpi/glyphs.py
# makes 2x versions of the arrow button images here, from the same file.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardScrollBars
BUNDLE="build/$NAME.bundle"
EXTRAS2=/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Resources/Extras2.rsrc

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp Info.plist "$BUNDLE/Contents/Info.plist"
python hidpi/glyphs.py "$EXTRAS2" ThemeTable.inc "$BUNDLE/Contents/Resources/SLScrollArt@2x.bin"

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m SLCalendar.m

echo "Built $BUNDLE"

