#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root="$(mktemp -d /tmp/install_ios_test.XXXXXX)"
trap 'rm -rf "$temporary_root"' EXIT
fake_bin="$temporary_root/bin"
fake_app="$temporary_root/Voice Input.app"
command_log="$temporary_root/commands.log"
devices_json="$temporary_root/devices.json"
mkdir -p "$fake_bin" "$fake_app"

jq -n '{result: {devices: [
  {
    identifier: "AVAILABLE-ID",
    deviceProperties: {name: "Available iPhone"},
    hardwareProperties: {
      deviceType: "iPhone",
      marketingName: "iPhone 16",
      reality: "physical",
      udid: "AVAILABLE-UDID"
    },
    connectionProperties: {pairingState: "paired", tunnelState: "connected"}
  },
  {
    identifier: "STALE-ID",
    deviceProperties: {name: "Stale iPhone"},
    hardwareProperties: {
      deviceType: "iPhone",
      marketingName: "iPhone 15",
      reality: "physical",
      udid: "STALE-UDID"
    },
    connectionProperties: {pairingState: "paired", tunnelState: "unavailable"}
  }
]}}' > "$devices_json"

printf '%s\n' \
  '#!/bin/zsh' \
  'set -euo pipefail' \
  'print -r -- "$*" >> "$HC_INSTALL_IOS_TEST_LOG"' \
  'if [[ "$*" == "devicectl list devices"* ]]; then' \
  '  output_path="${@[$#]}"' \
  '  cp "$HC_INSTALL_IOS_TEST_DEVICES" "$output_path"' \
  'elif [[ "$*" == "devicectl device install app"* && "${HC_INSTALL_IOS_TEST_INSTALL_FAILURE:-0}" == "1" ]]; then' \
  '  print -u2 "ApplicationVerificationFailed: The maximum number of apps for free development profiles has been reached."' \
  '  exit 1' \
  'fi' > "$fake_bin/xcrun"
chmod +x "$fake_bin/xcrun"

printf '%s\n' \
  '#!/bin/zsh' \
  'set -euo pipefail' \
  'print -r -- "build $*" >> "$HC_INSTALL_IOS_TEST_LOG"' \
  'print "$HC_INSTALL_IOS_TEST_APP"' > "$fake_bin/build_ios_device"
chmod +x "$fake_bin/build_ios_device"

plutil -create xml1 "$fake_app/Info.plist"
plutil -insert CFBundleIdentifier -string com.example.voice_input "$fake_app/Info.plist"

export PATH="$fake_bin:$PATH"
export HC_INSTALL_IOS_BUILD_SCRIPT="$fake_bin/build_ios_device"
export HC_INSTALL_IOS_TEST_APP="$fake_app"
export HC_INSTALL_IOS_TEST_DEVICES="$devices_json"
export HC_INSTALL_IOS_TEST_LOG="$command_log"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    print -u2 "Expected failure: $*"
    exit 1
  fi
}

help_output="$($repo_root/scripts/install_ios.sh --help)"
[[ "$help_output" == *"--config"* ]]
[[ "$help_output" != *"--configuration"* ]]
build_help_output="$($repo_root/scripts/build_ios_device.sh --help)"
[[ "$build_help_output" == *"--config"* ]]
expect_failure "$repo_root/scripts/build_ios_device.sh" --configuration Debug
expect_failure "$repo_root/scripts/build_ios_device.sh" --config prod

: > "$command_log"
"$repo_root/scripts/install_ios.sh" --device AVAILABLE-ID --config local_qa >/dev/null
grep -Fxq "build --config local_qa" "$command_log"
grep -Fq "devicectl device install app --device AVAILABLE-ID $fake_app" "$command_log"
grep -Fxq "devicectl device process launch --device AVAILABLE-ID com.example.voice_input" "$command_log"

expect_failure "$repo_root/scripts/install_ios.sh" --configuration Debug
expect_failure "$repo_root/scripts/install_ios.sh" --device AVAILABLE-ID --config prod

: > "$command_log"
print '1\n2' | "$repo_root/scripts/install_ios.sh" >/dev/null
grep -Fxq "build --config local_qa" "$command_log"
grep -Fq -- "--device AVAILABLE-ID" "$command_log"
if grep -Fq "STALE-ID" "$command_log"; then
  print -u2 "Unavailable devices must not be selectable."
  exit 1
fi

: > "$command_log"
failure_output="$(HC_INSTALL_IOS_TEST_INSTALL_FAILURE=1 \
  "$repo_root/scripts/install_ios.sh" --device AVAILABLE-ID --config development 2>&1 || true)"
[[ "$failure_output" == *"free development profile"* ]]
if grep -Fq "uninstall" "$command_log"; then
  print -u2 "The installer must never remove an existing app."
  exit 1
fi

print "install_ios tests passed."
