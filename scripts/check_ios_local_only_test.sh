#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check_ios_local_only.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Builds a clean tree: every searched target, and model downloads linked only
# by the containing app and its tests.
make_fixture() {
  rm -rf "$fixture" && mkdir -p "$fixture"
  cd "$fixture"
  local root=apps/ios/voice_input
  for target in app config keyboard shared system_capture widgets; do
    mkdir -p "$root/$target"
    print 'import Foundation' > "$root/$target/source.swift"
  done
  print -l 'targets:' \
    '  VoiceInput:' '    dependencies:' '      - target: HardwareControllerModelDownload' \
    '  VoiceInputKeyboard:' '    dependencies:' '      - target: VoiceInputShared' \
    '  VoiceInputTests:' '    dependencies:' '      - target: HardwareControllerModelDownload' \
    > "$root/project.yml"
}

# Applies one mutation to a fresh fixture and checks the outcome.
expect() {
  local outcome="$1" message="$2" mutation="$3"
  make_fixture
  eval "$mutation"
  if HC_IOS_LOCAL_ONLY_ROOT="$fixture" "$script" >/dev/null 2>&1; then
    [[ "$outcome" == pass ]] || { print -u2 "Expected failure: $message"; exit 1; }
  else
    [[ "$outcome" == fail ]] || { print -u2 "Expected success: $message"; exit 1; }
  fi
}

root=apps/ios/voice_input
expect pass "a local-only tree" ':'
expect fail "a network API in a source" "print 'let s = URLSession.shared' >> $root/shared/source.swift"
expect fail "the Network framework" "print 'import Network' >> $root/keyboard/source.swift"
expect fail "a cloud entitlement" "print '<key>com.apple.developer.icloud-services</key>' > $root/config/app.entitlements"
expect fail "transport security in a plist" "print '<key>NSAppTransportSecurity</key>' > $root/config/info.plist"
expect fail "an extension linking model downloads" \
  "perl -pi -e 's/target: VoiceInputShared/target: HardwareControllerModelDownload/' $root/project.yml"
expect fail "a missing target directory" "rm -r $root/widgets"
print "check_ios_local_only tests passed."
