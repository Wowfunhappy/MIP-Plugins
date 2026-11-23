#!/bin/bash
# Builds build/SnowLeopardScrollBars.bundle (i386 + x86_64).
# To install, copy it into /usr/share/mip/Bundles/ and relaunch your apps.
#
# The scroll bar art is read at run time from the system (Extras2.rsrc, the
# same file 10.6 used). For Retina displays, 2x versions of it are rendered
# here from Snow Leopard's CoreUI recipes, which are not part of this
# repository: pass the path to 10.6's CoreUI.framework/Versions/A/Resources/
# UI.bundle, or set SL_UIBUNDLE; without either, the copy on a mounted Snow
# Leopard install DVD is used. See hidpi/build_hidpi.py. That step needs OS X
# 10.9; without UI.bundle the plugin is built with 1x art only.
set -e
cd "$(dirname "$0")"

NAME=SnowLeopardScrollBars
BUNDLE="build/$NAME.bundle"

UIBUNDLE="${1:-${SL_UIBUNDLE:-/Volumes/Mac OS X Install DVD/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources/UI.bundle}}"

rm -rf "$BUNDLE" build/tools
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources" build/tools
cp Info.plist "$BUNDLE/Contents/Info.plist"

if [ -d "$UIBUNDLE/Contents/Recipes" ]; then
    clang -arch x86_64 -Os -Wall -framework Cocoa -o build/tools/render_server hidpi/render_server.m
    clang -arch x86_64 -Os -Wall -dynamiclib -framework ApplicationServices \
        -o build/tools/render_cache.dylib hidpi/render_cache.c
    python hidpi/build_hidpi.py "$UIBUNDLE" build/tools "$BUNDLE/Contents/Resources/SLScrollArt@2x.bin"
else
    echo "Snow Leopard's UI.bundle not found at $UIBUNDLE: building with 1x art only." >&2
fi

clang -bundle -arch i386 -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc \
    -framework Cocoa -framework QuartzCore \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    SLScrollBars.m SLDraw.m SLWebKit.m SLArt.m

echo "Built $BUNDLE"

