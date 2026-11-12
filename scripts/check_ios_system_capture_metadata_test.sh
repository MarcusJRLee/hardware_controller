#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check_ios_system_capture_metadata.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
app="$fixture/VoiceInput.app"
app_metadata="$app/Metadata.appintents/extract.actionsdata"
widget_metadata="$app/PlugIns/VoiceInputWidgets.appex/Metadata.appintents/extract.actionsdata"
protocol=com.apple.link.systemProtocol

# Writes metadata both targets must expose; each jq filter breaks one claim.
make_fixture() {
  rm -rf "$app"
  mkdir -p "${app_metadata:h}" "${widget_metadata:h}"
  jq -n --arg p "$protocol" '{
    actions: {
      VoiceInputStartIntent: {openAppWhenRun: true, systemProtocols: ["\($p).AudioRecording"]},
      VoiceInputStopIntent: {openAppWhenRun: false, systemProtocols: ["\($p).AudioRecording", "\($p).SessionStarting"]},
      VoiceInputSetCaptureIntent: {openAppWhenRun: true, systemProtocols: ["\($p).AudioRecording", "\($p).SetValue"]}
    },
    autoShortcuts: [{actionIdentifier: "VoiceInputStopIntent"}, {actionIdentifier: "VoiceInputStartIntent"}]
  }' | tee "$app_metadata" > "$widget_metadata"
}

expect() {
  local outcome="$1" message="$2" file="$3" filter="$4"
  make_fixture
  jq "$filter" "$file" > "$fixture/edited" && mv "$fixture/edited" "$file"
  if "$script" "$app" >/dev/null 2>&1; then
    [[ "$outcome" == pass ]] || { print -u2 "Expected failure: $message"; exit 1; }
  else
    [[ "$outcome" == fail ]] || { print -u2 "Expected success: $message"; exit 1; }
  fi
}

expect pass "complete metadata" "$app_metadata" '.'
expect fail "a missing widget intent" "$widget_metadata" 'del(.actions.VoiceInputSetCaptureIntent)'
expect fail "Stop opening the app" "$app_metadata" '.actions.VoiceInputStopIntent.openAppWhenRun = true'
expect fail "an extra App Shortcut" "$app_metadata" '.autoShortcuts += [{actionIdentifier: "VoiceInputSetCaptureIntent"}]'
expect fail "a widget Stop without session starting" "$widget_metadata" \
  ".actions.VoiceInputStopIntent.systemProtocols = [\"$protocol.AudioRecording\"]"
make_fixture
rm "$widget_metadata"
if "$script" "$app" >/dev/null 2>&1; then
  print -u2 "Expected failure: missing widget metadata"
  exit 1
fi
print "check_ios_system_capture_metadata tests passed."
