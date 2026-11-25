#!/bin/bash
# Builds build/ArchiveUtilityPlus.bundle (x86_64: Archive Utility and Finder are
# 64-bit only, and don't use garbage collection).
# To install, copy the bundle into /usr/share/mip/Bundles/ and relaunch Finder
# and Archive Utility.
set -e
cd "$(dirname "$0")"

NAME=ArchiveUtilityPlus
BUNDLE="build/$NAME.bundle"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y.%m.%d)" "$BUNDLE/Contents/Info.plist" > /dev/null
chmod 644 "$BUNDLE/Contents/Info.plist"
# 7zz, the icons app, and the library 7zz links (@executable_path/../Frameworks).
cp -R Resources Frameworks "$BUNDLE/Contents/"

clang -bundle -arch x86_64 -mmacosx-version-min=10.9 \
    -Os -Wall -Wno-deprecated-declarations -fno-objc-arc -I../ZKSwizzle \
    -framework Cocoa -framework CoreServices \
    -o "$BUNDLE/Contents/MacOS/$NAME" \
    ArchiveUtilityPlus.m ../ZKSwizzle/ZKSwizzle.m

echo "Built $BUNDLE"
