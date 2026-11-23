#!/bin/bash
# Makes the artwork SnowLeopardScrollBars bundles into build/assets/, where
# build.sh takes it from. Run it once (and again if the extraction changes).
#
# The scroll bar art itself is read at run time from the system (Extras2.rsrc,
# the same file 10.6 used). On Retina displays it is drawn scaled up, as 10.6
# did, except that the arrow buttons' triangles are redrawn sharp:
#
#   SLScrollArt@2x.bin  2x versions of the arrow button images, made from the
#                       same file (hidpi/glyphs.py)
set -e
cd "$(dirname "$0")"

EXTRAS2=/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Resources/Extras2.rsrc

# Built in a scratch folder and moved into place at the end, so build/assets
# is only ever complete.
WORK=build/extract
OUT=$WORK/assets
rm -rf "$WORK"
mkdir -p "$OUT"

python hidpi/glyphs.py "$EXTRAS2" ThemeTable.inc "$OUT/SLScrollArt@2x.bin"

rm -rf build/assets
mv "$OUT" build/assets
rm -rf "$WORK"
echo "Extracted to build/assets"
