#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v cargo >/dev/null || {
  print -u2 "cargo is required to build the iOS Voice validator."
  exit 1
}
command -v rustup >/dev/null || {
  print -u2 "rustup is required to install and verify iOS Rust targets."
  exit 1
}

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$target" || {
    print -u2 "Rust target $target is required. Run: rustup target add $target"
    exit 1
  }
  cargo build \
    --package voice_ffi \
    --release \
    --locked \
    --target "$target"
done

output_root="$repo_root/.build/ios_voice_ffi"
xcframework="$output_root/VoiceFFI.xcframework"
mkdir -p "$output_root"
rm -rf "$xcframework"
headers="$output_root/headers"
rm -rf "$headers"
mkdir -p "$headers"
cp "$repo_root/crates/voice_ffi/include/voice_ffi.h" "$headers/voice_ffi.h"
cp "$repo_root/Sources/voice_ffi_bridge/include/voice_ffi_bridge.h" \
  "$headers/voice_ffi_bridge.h"
sed -i '' 's#../../../crates/voice_ffi/include/voice_ffi.h#voice_ffi.h#' \
  "$headers/voice_ffi_bridge.h"
cp "$repo_root/Sources/voice_ffi_bridge/include/module.modulemap" \
  "$headers/module.modulemap"
xcodebuild -create-xcframework \
  -library "$repo_root/target/aarch64-apple-ios/release/libvoice_ffi.a" \
  -headers "$headers" \
  -library "$repo_root/target/aarch64-apple-ios-sim/release/libvoice_ffi.a" \
  -headers "$headers" \
  -output "$xcframework" >/dev/null

for library in "$xcframework"/*/libvoice_ffi.a; do
  symbols="$(nm -g "$library" 2>/dev/null || true)"
  [[ "$symbols" == *"_voice_model_package_validate_v1"* ]] || {
    print -u2 "$library does not export voice_model_package_validate_v1."
    exit 1
  }
  [[ "$symbols" == *"_voice_model_package_validate_v2"* ]] || {
    print -u2 "$library does not export voice_model_package_validate_v2."
    exit 1
  }
done

print "$xcframework"
