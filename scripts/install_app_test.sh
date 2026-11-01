#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
unset HC_CODE_SIGN_IDENTITY HC_EXPECTED_TEAM_ID
export HC_INSTALL_PATH="$fixture/Applications/Hardware Controller.app"
export HC_BUILT_APP="$fixture/built.app"
source "$repo_root/scripts/install_app.sh"

expect_failure() {
  if ("$@") >/dev/null 2>&1; then
    print -u2 "Expected failure: $*"
    exit 1
  fi
}

# Writes one signing environment file and loads it in a subshell.
loads_environment() {
  print -r -- "$1" > "$fixture/env"
  (HC_ENV_FILE="$fixture/env" load_signing_environment)
}

# Signing values must be explicit, non-ad-hoc, and backed by a valid identity.
test_signing_environment() {
  expect_failure loads_environment 'HC_CODE_SIGN_IDENTITY="-"
HC_EXPECTED_TEAM_ID="TEAM123"'
  expect_failure loads_environment 'HC_CODE_SIGN_IDENTITY="Apple Development: Nobody (NONE)"'
  expect_failure loads_environment 'HC_CODE_SIGN_IDENTITY="Apple Development: Nobody (NONE)"
HC_EXPECTED_TEAM_ID="TEAM123"'
  expect_failure env HC_ENV_FILE="$fixture/absent" zsh -c "source '$repo_root/scripts/install_app.sh'; load_signing_environment"
}

# An ad-hoc bundle can never pass the install policy.
test_ad_hoc_bundle_is_rejected() {
  mkdir -p "$HC_BUILT_APP/Contents/MacOS"
  cp "$repo_root/packaging/Info.plist" "$HC_BUILT_APP/Contents/Info.plist"
  cp /usr/bin/true "$HC_BUILT_APP/Contents/MacOS/HardwareController"
  codesign --force --sign - "$HC_BUILT_APP" >/dev/null 2>&1
  expect_failure verify_bundle "$HC_BUILT_APP"
}

# Replacing the canonical copy leaves exactly one bundle and no staging copy.
test_replace_canonical() {
  mkdir -p "$HC_INSTALL_PATH/Contents"
  print stale > "$HC_INSTALL_PATH/Contents/stale"
  replace_canonical
  [[ ! -e "$HC_INSTALL_PATH/Contents/stale" ]]
  cmp -s "$HC_BUILT_APP/Contents/MacOS/HardwareController" \
    "$HC_INSTALL_PATH/Contents/MacOS/HardwareController"
  [[ "$(ls -A "${HC_INSTALL_PATH:h}")" == "${HC_INSTALL_PATH:t}" ]]
}

test_signing_environment
test_ad_hoc_bundle_is_rejected
test_replace_canonical
print "install_app tests passed."
