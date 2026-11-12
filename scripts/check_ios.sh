#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v jq >/dev/null || {
  print -u2 "jq is required to select a simulator and report test failures."
  exit 1
}
simulator_udid="${HC_IOS_SIMULATOR_UDID:-}"
if [[ -z "$simulator_udid" ]]; then
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
# Booting takes minutes on CI; start it now so it overlaps checks and the build.
xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 &
derived_data="$(mktemp -d /tmp/hardware_controller_ios_check.XXXXXX)"
trap 'rm -rf "$derived_data"' EXIT

scripts/generate_ios_project.sh
git diff --exit-code -- apps/ios/voice_input/VoiceInput.xcodeproj

scripts/check_ios_local_only_test.sh
scripts/check_ios_system_capture_metadata_test.sh
scripts/check_ios_local_only.sh
scripts/swift_format.sh lint --recursive --strict apps/ios/voice_input
plutil -lint apps/ios/voice_input/config/*.plist >/dev/null
# CI runs these in the Verify job; standalone runs keep them.
if [[ "${HC_IOS_SKIP_SHARED_CHECKS:-0}" != "1" ]]; then
  scripts/check_voice_asr_bridge.sh
  scripts/prepare_ios_asr_model_package_test.sh
fi

xcode_test_flags=(
  -project apps/ios/voice_input/VoiceInput.xcodeproj
  -scheme VoiceInput
  -destination "$destination"
  -derivedDataPath "$derived_data"
  -parallel-testing-enabled NO
)
# Building needs no booted simulator, so it runs while the boot finishes.
xcodebuild build-for-testing -quiet "${xcode_test_flags[@]}" \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl privacy "$simulator_udid" grant microphone \
  com.longdevity.hardwarecontroller.voiceinput
# UI tests drive real capture with this recorded clip in place of the microphone.
jfk_fixture="$(scripts/fetch_asr_test_assets.sh | grep '/jfk\.wav$')"
result_bundle="$derived_data/tests.xcresult"
if ! TEST_RUNNER_VOICE_INPUT_AUDIO_FIXTURE="$jfk_fixture" \
  xcodebuild test-without-building -quiet "${xcode_test_flags[@]}" \
  -resultBundlePath "$result_bundle"; then
  # -quiet hides assertion text; print each failure so CI logs are actionable.
  xcrun xcresulttool get test-results summary --path "$result_bundle" --compact \
    | jq -r '.testFailures[] | "\(.testIdentifierString): \(.failureText)"' >&2
  exit 1
fi

scripts/check_ios_system_capture_metadata.sh \
  "$derived_data/Build/Products/Debug-iphonesimulator/VoiceInput.app"
