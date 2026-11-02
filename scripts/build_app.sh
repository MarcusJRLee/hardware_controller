#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app_bundle="dist/Hardware Controller.app"
contents="$app_bundle/Contents"
iconset=".build/AppIcon.iconset"
# An ad-hoc signature is only for throwaway CI and smoke builds; it must be
# requested explicitly so it can never be installed by accident.
if [[ "${1:-}" == "--ad-hoc" ]]; then
  sign_identity="-"
elif [[ -n "${HC_CODE_SIGN_IDENTITY:-}" && "$HC_CODE_SIGN_IDENTITY" != "-" ]]; then
  sign_identity="$HC_CODE_SIGN_IDENTITY"
else
  print -u2 "Set HC_CODE_SIGN_IDENTITY (see .env.example) or pass --ad-hoc."
  exit 1
fi

scripts/build_rust_ffi.sh
runtime="$(scripts/fetch_asr_runtime.sh)/macos-arm64_x86_64"
swift build -c release --product HardwareController
swift build -c release --product HardwareControllerASRService
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

# The ASR service is the only code that links transcribe.cpp (decision 0060).
service="$contents/XPCServices/HardwareControllerASRService.xpc"
service_binary="$service/Contents/MacOS/HardwareControllerASRService"
mkdir -p "$service/Contents/MacOS" "$service/Contents/Frameworks"
cp "$binary_directory/HardwareControllerASRService" "$service_binary"
ditto "$runtime/CTranscribe.framework" "$service/Contents/Frameworks/CTranscribe.framework"
cp "packaging/asr_service_info.plist" "$service/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist")"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$service/Contents/Info.plist"
done
# Build-tree rpaths must not ship; the service loads only its bundled framework.
for rpath in "${(@f)$(otool -l "$service_binary" | awk '/LC_RPATH/ {getline; getline; print $2}')}"; do
  [[ "$rpath" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$rpath" "$service_binary"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$service_binary"

# Sign inside out: framework, service, then app. `--deep` would apply the app's
# entitlements to the service, which needs none.
signing_flags=(--force --options runtime --sign "$sign_identity")
codesign "${signing_flags[@]}" "$service/Contents/Frameworks/CTranscribe.framework"
codesign "${signing_flags[@]}" "$service"
codesign \
  "${signing_flags[@]}" \
  --entitlements "packaging/HardwareController.entitlements" \
  "$app_bundle"

codesign --verify --deep --strict --verbose=2 "$app_bundle"
plutil -lint "$contents/Info.plist" >/dev/null
plutil -lint "$service/Contents/Info.plist" >/dev/null

echo "$app_bundle"
