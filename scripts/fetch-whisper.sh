#!/bin/bash
# Builds whisper.xcframework (Metal + Core ML) from whisper.cpp at the commit this app is tested with and
# puts it in Vendor/. Needs Xcode and cmake (`brew install cmake`). Takes a few minutes; run once.
set -euo pipefail
cd "$(dirname "$0")/.."
COMMIT=080bbbe8        # whisper.cpp v1.9.1-154, 2026-07-11
SRC="${WHISPER_SRC:-.build/whisper.cpp}"
if [ -e Vendor/whisper.xcframework ]; then echo "Vendor/whisper.xcframework already exists"; exit 0; fi
command -v cmake >/dev/null || { echo "cmake is missing: brew install cmake"; exit 1; }
if [ ! -d "$SRC/.git" ]; then git clone https://github.com/ggml-org/whisper.cpp "$SRC"; fi
git -C "$SRC" fetch --quiet origin && git -C "$SRC" checkout --quiet "$COMMIT"
(cd "$SRC" && ./build-xcframework.sh)
mkdir -p Vendor
cp -R "$SRC/build-apple/whisper.xcframework" Vendor/whisper.xcframework
echo "built Vendor/whisper.xcframework"
