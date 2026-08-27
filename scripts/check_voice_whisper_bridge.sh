#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

xcframework="$(scripts/fetch_ios_asr_runtime.sh)"
assets=("${(@f)$(scripts/fetch_ios_asr_test_assets.sh)}")
output_root="$repo_root/.build/voice_whisper_bridge_test"
mkdir -p "$output_root"

clang \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$repo_root/Sources/voice_whisper_bridge/include" \
  -F "$xcframework/macos-arm64_x86_64" \
  -framework whisper \
  -Wl,-rpath,"$xcframework/macos-arm64_x86_64" \
  "$repo_root/Sources/voice_whisper_bridge/voice_whisper_bridge.c" \
  "$repo_root/Tests/voice_whisper_bridge_tests/voice_whisper_bridge_test.c" \
  -o "$output_root/voice_whisper_bridge_test"

"$output_root/voice_whisper_bridge_test" "${assets[1]}" "${assets[2]}"
print "Voice whisper bridge integration passed."
