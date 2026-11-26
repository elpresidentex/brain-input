#!/bin/bash
# Builds the downloadable release: a Developer ID signed, notarized, stapled DMG in build/.
#   VERSION=0.1.0 scripts/release.sh
# Notarization needs credentials stored once in the keychain (the command asks for an app-specific password
# from https://account.apple.com › Sign-In and Security › App-Specific Passwords):
#   xcrun notarytool store-credentials brain-input-notary --apple-id <your Apple ID> --team-id <team id>
# Without that profile the script still builds and signs the DMG and says that it is not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION="${VERSION:-0.1.0}"
PROFILE="${NOTARY_PROFILE:-brain-input-notary}"
RELEASE=1 scripts/build-app.sh
APP=build/BrainInput.app
DMG="build/BrainInput-$VERSION.dmg"
codesign --verify --deep --strict "$APP"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/Brain Input.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Brain Input" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
codesign --force --timestamp --sign "$ID" "$DMG"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "notarized: $DMG"
else
  echo "NOT NOTARIZED: no keychain profile '$PROFILE'. Gatekeeper will block this DMG on other Macs. See the top of this script."
fi
shasum -a 256 "$DMG"
# The landing page links to .../releases/latest/download/BrainInput-latest.dmg, so each release also needs a copy without the version.
# Upload both:  gh release upload "v$VERSION" "$DMG" build/BrainInput-latest.dmg --clobber
cp "$DMG" build/BrainInput-latest.dmg
