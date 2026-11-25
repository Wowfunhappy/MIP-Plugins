#!/bin/bash
# Builds build/KeynoteScrollPresentation.bundle (x86_64: Keynote 6 is 64-bit
# only, and doesn't use garbage collection).
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch Keynote.
set -e
cd "$(dirname "$0")"

NAME=KeynoteScrollPresentation
BUNDLE="build/$NAME.bundle"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y.%m.%d)" "$BUNDLE/Contents/Info.plist" > /dev/null
chmod 644 "$BUNDLE/Contents/Info.plist"

clang -bundle -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc -I../ZKSwizzle \
    -framework Cocoa \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    KeynoteScrollPresentation.m ../ZKSwizzle/ZKSwizzle.m

echo "Built $BUNDLE"
