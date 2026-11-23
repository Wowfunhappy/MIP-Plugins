#!/bin/bash
# Extracts the Snow Leopard artwork SnowLeopardWindows uses into build/assets/,
# where build.sh takes it from. Run it once (and again if the extraction
# changes); none of it is part of this repository.
#
#   ./extract.sh [/path/to/ArtFile.bin]
#
# Everything comes from a Mac OS X 10.6 install DVD; by default the one mounted
# at /Volumes/Mac OS X Install DVD, or give the path to 10.6's
# CoreUI.framework/Versions/A/Resources/ArtFile.bin (or set SL_ARTFILE):
#
#   SLWindowArt.bin     title bar button images, from 10.6's CoreUI ArtFile.bin
#                       (extract_art.py)
#   SLWindowArt@2x.bin  the same at 2x for Retina displays, rendered from 10.6's
#                       resolution-independent recipes (UI.bundle, next to
#                       ArtFile.bin) with Mavericks' own renderer
#                       (render_hidpi.m; needs OS X 10.9)
#   SLTabArt/           Safari 4's tab images ("AW"/"IW" PNGs), from Safari.pkg
#                       on the DVD (or SL_SAFARIPKG)
#   SLQuickTimeArt/     QuickTime Player X's title bar buttons, from
#                       Essentials.pkg on the DVD (or SL_ESSENTIALSPKG)
set -e
cd "$(dirname "$0")"

ARTFILE="${1:-${SL_ARTFILE:-/Volumes/Mac OS X Install DVD/System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources/ArtFile.bin}}"
UIBUNDLE="$(dirname "$ARTFILE")/UI.bundle"
# The DVD's root: ArtFile.bin is in System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/Resources.
DVDROOT="$(cd "$(dirname "$ARTFILE")/../../../../../../.." 2>/dev/null && pwd)"
SAFARIPKG="${SL_SAFARIPKG:-$DVDROOT/System/Installation/Packages/Safari.pkg}"
ESSENTIALSPKG="${SL_ESSENTIALSPKG:-$DVDROOT/System/Installation/Packages/Essentials.pkg}"

for input in "$ARTFILE" "$UIBUNDLE/Contents/Recipes" "$SAFARIPKG" "$ESSENTIALSPKG"; do
    if [ ! -e "$input" ]; then
        echo "Not found: $input" >&2
        echo "Mount a Mac OS X 10.6 install DVD, or pass the path to 10.6's" >&2
        echo "CoreUI.framework/Versions/A/Resources/ArtFile.bin as an argument." >&2
        exit 1
    fi
done

# Built in a scratch folder and moved into place at the end, so build/assets
# is only ever complete.
WORK=build/extract
OUT=$WORK/assets
rm -rf "$WORK"
mkdir -p "$OUT/SLTabArt" "$OUT/SLQuickTimeArt" "$WORK/tools"

# 10.6's title bar buttons.
python extract_art.py "$ARTFILE" "$OUT/SLWindowArt.bin" "$WORK/tools/tags.plist"

# ...and at 2x, rendered from 10.6's recipes.
clang -arch x86_64 -Os -Wall -framework Cocoa -o "$WORK/tools/render_hidpi" render_hidpi.m
clang -arch x86_64 -Os -Wall -dynamiclib -framework ApplicationServices \
    -o "$WORK/tools/render_hidpi_cache.dylib" render_hidpi_cache.c
DYLD_INSERT_LIBRARIES="$PWD/$WORK/tools/render_hidpi_cache.dylib" "$WORK/tools/render_hidpi" \
    "$UIBUNDLE" "$WORK/tools/tags.plist" "$OUT/SLWindowArt.bin" "$OUT/SLWindowArt@2x.bin"

# Safari 4's tab images.
mkdir -p "$WORK/safari"
(cd "$WORK/safari" && xar -xf "$SAFARIPKG" Payload && gzip -dc Payload |
    cpio -id './Applications/Safari.app/Contents/Resources/AW *.png' './Applications/Safari.app/Contents/Resources/IW *.png' 2>/dev/null)
cp "$WORK/safari/Applications/Safari.app/Contents/Resources/"[AI]W\ *.png "$OUT/SLTabArt/"

# QuickTime Player X's title bar buttons.
mkdir -p "$WORK/essentials"
(cd "$WORK/essentials" && xar -xf "$ESSENTIALSPKG" Payload && gzip -dc Payload |
    cpio -id './Applications/QuickTime Player.app/Contents/Resources/close*.tiff' \
             './Applications/QuickTime Player.app/Contents/Resources/minimize*.tiff' \
             './Applications/QuickTime Player.app/Contents/Resources/zoom*.tiff' 2>/dev/null)
cp "$WORK/essentials/Applications/QuickTime Player.app/Contents/Resources/"*.tiff "$OUT/SLQuickTimeArt/"

rm -rf build/assets
mv "$OUT" build/assets
rm -rf "$WORK"
echo "Extracted to build/assets"
