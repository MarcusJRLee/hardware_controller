#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

simulator_udid="${HC_IOS_SIMULATOR_UDID:-}"
if [[ -z "$simulator_udid" ]]; then
  command -v jq >/dev/null || {
    print -u2 "jq or HC_IOS_SIMULATOR_UDID is required to select an iOS simulator."
    exit 1
  }
  simulator_udid="$(xcrun simctl list devices available -j \
    | jq -r '
      ([.devices[][] | select(.isAvailable == true and .name == "iPhone 17 Pro")][0]
        // [.devices[][] | select(.isAvailable == true and (.name | startswith("iPhone")))][0]
      ).udid // empty
    ')"
fi
[[ -n "$simulator_udid" ]] || {
  print -u2 "No iPhone simulator is available; set HC_IOS_SIMULATOR_UDID."
  exit 1
}

destination="${HC_IOS_SIMULATOR_DESTINATION:-platform=iOS Simulator,id=$simulator_udid}"
derived_data="$(mktemp -d /tmp/hardware_controller_ios_check.XXXXXX)"
trap 'rm -rf "$derived_data"' EXIT

scripts/generate_ios_project.sh
git diff --exit-code -- apps/ios/voice_input/VoiceInput.xcodeproj

scripts/check_ios_local_only.sh
swift format lint --recursive --strict apps/ios/voice_input
plutil -lint apps/ios/voice_input/config/*.plist >/dev/null
scripts/check_voice_whisper_bridge.sh
scripts/prepare_ios_whisper_model_package_test.sh

xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl privacy "$simulator_udid" grant microphone \
  com.longdevity.hardwarecontroller.voiceinput

xcodebuild test -quiet \
  -project apps/ios/voice_input/VoiceInput.xcodeproj \
  -scheme VoiceInput \
  -destination "$destination" \
  -derivedDataPath "$derived_data" \
  -parallel-testing-enabled NO
