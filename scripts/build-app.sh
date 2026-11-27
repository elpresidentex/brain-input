#!/bin/bash
# Builds build/BrainInput.app (release), embeds whisper.framework and the `brain` CLI, and signs it
# with a stable identity so macOS keeps granted permissions across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
# Refuse to build a checkout that is behind local master: such a build silently drops fixes (0.1.1 was built that way
# and lost the top-right meeting counter). ALLOW_STALE=1 builds it anyway. Skipped where there is no master branch.
if [ "${ALLOW_STALE:-0}" != 1 ] && git rev-parse -q --verify refs/heads/master >/dev/null 2>&1 \
   && ! git merge-base --is-ancestor refs/heads/master HEAD; then
  echo "not building: this checkout lacks $(git rev-list --count HEAD..refs/heads/master) commit(s) on master, for example:" >&2
  git log -5 --format='  %h %s' HEAD..refs/heads/master >&2
  echo "merge master first, or run again with ALLOW_STALE=1" >&2
  exit 1
fi
# Link VoiceInk's prebuilt whisper.xcframework if this Mac has it; otherwise build it from whisper.cpp.
[ -e Vendor/whisper.xcframework ] || scripts/setup-vendor.sh --quiet
[ -e Vendor/whisper.xcframework ] || scripts/fetch-whisper.sh
VERSION="${VERSION:-0.1.0}"
# Oldest macOS the app runs on. Keep in step with `platforms` in Package.swift; the check below enforces it.
MIN_OS=15.0
swift build -c release 2>&1 | tail -3
BIN=.build/release
APP=build/BrainInput.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/BrainInputApp" "$APP/Contents/MacOS/BrainInput"
cp "$BIN/brain" "$APP/Contents/MacOS/brain"
cp Assets/AppIcon.icns Assets/MenuBarIcon*.png "$APP/Contents/Resources/"
ditto Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$APP/Contents/Frameworks/whisper.framework"
for b in BrainInput brain; do install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$b" 2>/dev/null || true; done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.arminbognar.BrainInput</string>
  <key>CFBundleName</key><string>Brain Input</string>
  <key>CFBundleDisplayName</key><string>Brain Input</string>
  <key>CFBundleExecutable</key><string>BrainInput</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>Free software under GPL-3.0. No warranty.</string>
  <key>NSMicrophoneUsageDescription</key><string>Brain Input listens only while you hold the dictation key or record a meeting you started.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Brain Input records the other side of a call only during a meeting recording you started.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Brain Input reads the current calendar event to title meeting notes and list participants.</string>
</dict></plist>
PLIST
# Refuse an app whose binaries need a newer macOS than LSMinimumSystemVersion promises (a vendored whisper.framework
# built for a newer macOS would otherwise only fail on the user's Mac, with "cannot use this version of macOS").
for f in "$APP/Contents/MacOS/BrainInput" "$APP/Contents/MacOS/brain" "$APP/Contents/Frameworks/whisper.framework/whisper"; do
  m=$(vtool -show-build "$f" 2>/dev/null | awk '$1=="minos"{print $2}' | sort -V | tail -1)
  if [ -n "$m" ] && [ "$(printf '%s\n%s\n' "$m" "$MIN_OS" | sort -V | tail -1)" != "$MIN_OS" ]; then
    echo "not building: $f needs macOS $m, but the app promises macOS $MIN_OS" >&2; exit 1
  fi
done
# RELEASE=1: Developer ID, hardened runtime and a secure timestamp, as notarization requires (see scripts/release.sh).
if [ "${RELEASE:-0}" = 1 ]; then
  ID="${BRAININPUT_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
  [ -n "$ID" ] || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
  OPTS=(--force --timestamp --options runtime --entitlements scripts/BrainInput.entitlements)
else
  ID="${BRAININPUT_SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
  OPTS=(--force --timestamp=none)
fi
if [ -n "$ID" ]; then
  codesign "${OPTS[@]}" --sign "$ID" "$APP/Contents/Frameworks/whisper.framework"
  codesign "${OPTS[@]}" --sign "$ID" "$APP/Contents/MacOS/brain"
  codesign "${OPTS[@]}" --sign "$ID" "$APP"
  echo "signed with: $ID"
else
  codesign --force --deep --sign - "$APP"
  echo "WARNING: no signing identity found; ad-hoc signed (permissions reset on every rebuild)"
fi
echo "built $APP"
