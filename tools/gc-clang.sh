#!/bin/bash
# Prints the path of the compiler the plugins are built with: clang 3.4 from
# llvm.org (its prebuilt release for OS X 10.9), which can still build code
# for garbage collection (-fobjc-gc). Xcode's clang since Xcode 6 can't, and
# the plugins must also run in apps that use GC. It is downloaded into
# tools/build/ the first time, checked against the checksum below, and used
# from there; nothing is installed.
set -e
cd "$(dirname "$0")"

NAME=clang+llvm-3.4-x86_64-apple-darwin10.9
URL=https://releases.llvm.org/3.4/$NAME.tar.gz
SHA256=d07c79013f80f1c3c9077543e7d904eade09bb6ed2086042de009687e452f2e4
CLANG="$PWD/build/$NAME/bin/clang"

if [ ! -x "$CLANG" ]; then
    mkdir -p build
    echo "Downloading clang 3.4 from llvm.org..." >&2
    curl -fsSL -o "build/$NAME.tar.gz.part" "$URL"
    if [ "$(shasum -a 256 "build/$NAME.tar.gz.part" | cut -d' ' -f1)" != "$SHA256" ]; then
        echo "The download of $URL doesn't match its checksum." >&2
        rm -f "build/$NAME.tar.gz.part"
        exit 1
    fi
    tar -xzf "build/$NAME.tar.gz.part" -C build
    rm -f "build/$NAME.tar.gz.part"
fi
echo "$CLANG"
