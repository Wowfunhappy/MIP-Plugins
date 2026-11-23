#!/bin/bash
# Makes the artwork and text SnowLeopardScrollBars bundles into build/assets/,
# where build.sh takes them from. Run it once (and again if the extraction
# changes).
#
#   ./extract.sh [/path/to/Mac OS X Install DVD]
#
# The scroll bar art itself is read at run time from the system (Extras2.rsrc,
# the same file 10.6 used). On Retina displays it is drawn scaled up, as 10.6
# did, except that the arrow buttons' triangles are redrawn sharp:
#
#   SLScrollArt@2x.bin  2x versions of the arrow button images, made from the
#                       same file (hidpi/glyphs.py)
#
# The rest comes from a Mac OS X 10.6 install DVD; by default the one mounted
# at /Volumes/Mac OS X Install DVD (or set SL_DVD):
#
#   ArrowStrings/       10.6's "Place scroll arrows:" text, for the control the
#                       plugin adds to System Preferences' General pane
#                       (SLPrefPane.m), in each of 10.6's languages: read from
#                       10.6's General pane (Appearance.prefPane's LookPref.nib)
#                       in Essentials.pkg (English) and the language packages
#                       (arrowstrings.py)
set -e
cd "$(dirname "$0")"

EXTRAS2=/System/Library/Frameworks/Carbon.framework/Frameworks/HIToolbox.framework/Resources/Extras2.rsrc
DVD="${1:-${SL_DVD:-/Volumes/Mac OS X Install DVD}}"
PACKAGES="$DVD/System/Installation/Packages"
# Essentials.pkg has English; each language package has its language.
LANGUAGE_PACKAGES="Essentials BrazilianPortuguese Danish Dutch Finnish French German Italian Japanese
    Korean Norwegian Polish Portuguese Russian SimplifiedChinese Spanish Swedish TraditionalChinese"

for package in $LANGUAGE_PACKAGES; do
    if [ ! -e "$PACKAGES/$package.pkg" ]; then
        echo "Not found: $PACKAGES/$package.pkg" >&2
        echo "Mount a Mac OS X 10.6 install DVD, or pass the path to one as an argument." >&2
        exit 1
    fi
done

# Built in a scratch folder and moved into place at the end, so build/assets
# is only ever complete.
WORK="$PWD/build/extract"
OUT=$WORK/assets
rm -rf "$WORK"
mkdir -p "$OUT/ArrowStrings"

python hidpi/glyphs.py "$EXTRAS2" ThemeTable.inc "$OUT/SLScrollArt@2x.bin"

# 10.6's "Place scroll arrows:" text, in each language.
PANE=System/Library/PreferencePanes/Appearance.prefPane/Contents/Resources
for package in $LANGUAGE_PACKAGES; do
    dir="$WORK/packages/$package"
    mkdir -p "$dir"
    (cd "$dir" && xar -xf "$PACKAGES/$package.pkg" Payload && gzip -dc Payload |
        cpio -id "./$PANE/*.lproj/LookPref.nib/*" 2>/dev/null; rm -f Payload)
    found=0
    for nib in "$dir/$PANE/"*.lproj/LookPref.nib; do
        [ -e "$nib" ] || continue
        lproj="$(basename "$(dirname "$nib")")"
        mkdir -p "$OUT/ArrowStrings/$lproj"
        # (AppKit logs each of the nib's other connections as "Could not connect".)
        python -E -s arrowstrings.py "$nib" "$OUT/ArrowStrings/$lproj/SLScrollArrows.strings" 2>&1 |
            { grep -v "Could not connect" >&2 || true; }
        [ -s "$OUT/ArrowStrings/$lproj/SLScrollArrows.strings" ] || { echo "Failed: $nib" >&2; exit 1; }
        found=1
    done
    if [ $found = 0 ]; then
        echo "Not found in $package.pkg: $PANE/*.lproj/LookPref.nib" >&2
        exit 1
    fi
done

rm -rf build/assets
mv "$OUT" build/assets
rm -rf "$WORK"
echo "Extracted to build/assets"
