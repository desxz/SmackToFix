#!/bin/bash
# Builds a Release zip a Mac can install without Xcode.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/DerivedData"
app="$derived/Build/Products/Release/sMACk.app"

cd "$root"
rm -rf "$root/dist"
mkdir -p "$root/dist"

xcodebuild \
  -project SmackToFix.xcodeproj \
  -scheme SmackToFix \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  build

binary="$app/Contents/MacOS/sMACk"
if ! lipo -info "$binary" | grep -q 'arm64' || ! lipo -info "$binary" | grep -q 'x86_64'; then
  echo "Release binary is not universal." >&2
  lipo -info "$binary" >&2 || true
  exit 1
fi

stage="$root/dist/stage"
rm -rf "$stage"
mkdir -p "$stage"
cp -R "$app" "$stage/sMACk.app"
ln -s /Applications "$stage/Applications"
ditto -c -k --keepParent "$stage/sMACk.app" "$root/dist/SmackToFix.zip"
hdiutil create \
  -volname "sMACk" \
  -srcfolder "$stage" \
  -ov \
  -format UDZO \
  "$root/dist/SmackToFix.dmg" >/dev/null
rm -rf "$stage"
echo "$root/dist/SmackToFix.zip"
echo "$root/dist/SmackToFix.dmg"
