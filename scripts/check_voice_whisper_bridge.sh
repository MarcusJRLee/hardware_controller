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

performance_gate="${HC_RUN_IOS_ASR_PERFORMANCE:-0}"
[[ "$performance_gate" == "0" || "$performance_gate" == "1" ]] || {
  print -u2 "HC_RUN_IOS_ASR_PERFORMANCE must be 0 or 1."
  exit 1
}
arguments=("${assets[1]}" "${assets[2]}")
if [[ "$performance_gate" == "1" ]]; then
  arguments+=("0.75")
fi
"$output_root/voice_whisper_bridge_test" "${arguments[@]}"
print "Voice whisper bridge integration passed."
