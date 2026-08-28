#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_bundle="dist/Hardware Controller.app"
contents="$app_bundle/Contents"
iconset=".build/AppIcon.iconset"
sign_identity="${HC_CODE_SIGN_IDENTITY:--}"

scripts/build_rust_ffi.sh
swift build -c release --product HardwareController
binary_directory="$(swift build -c release --show-bin-path)"

rm -rf "dist/Hardware Controller.app"
rm -rf ".build/AppIcon.iconset"
mkdir -p "$contents/MacOS" "$contents/Resources" "$iconset"

cp "$binary_directory/HardwareController" \
  "$contents/MacOS/HardwareController"
cp "packaging/Info.plist" "$contents/Info.plist"

cp "packaging/app_icon_source.png" \
  ".build/AppIcon-1024.png"

sips -z 16 16 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 ".build/AppIcon-1024.png" \
  --out "$iconset/icon_512x512.png" >/dev/null
cp ".build/AppIcon-1024.png" \
  "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" \
  -o "$contents/Resources/AppIcon.icns"

codesign \
  --force \
  --deep \
  --options runtime \
  --sign "$sign_identity" \
  --entitlements "packaging/HardwareController.entitlements" \
  "$app_bundle"

codesign --verify --deep --strict --verbose=2 "$app_bundle"
plutil -lint "$contents/Info.plist" >/dev/null

echo "$app_bundle"
