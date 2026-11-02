#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/build_release.sh"

# Runs one command and requires it to fail.
expect_failure() {
  if ("$@") >/dev/null 2>&1; then
    print -u2 "Expected failure: $*"
    exit 1
  fi
}

# Verifies accepted and rejected release version forms.
test_release_version_validation() {
  verify_release_version "1.4.0"
  expect_failure verify_release_version "1.4"
  expect_failure verify_release_version "v1.4.0"
  expect_failure verify_release_version "1.4.0-beta"
}

# Verifies the release approval must name the packaged version exactly.
test_release_approval_validation() {
  verify_release_approval "1.4.0" "1.4.0"
  expect_failure verify_release_approval "1.4.0" ""
  expect_failure verify_release_approval "1.4.0" "1.4.1"
}

# Verifies exact private Team matching without embedding a real identifier.
test_team_identifier_validation() {
  verify_team_identifier "EXPECTED123" "EXPECTED123"
  expect_failure verify_team_identifier "OTHER123" "EXPECTED123"
  expect_failure verify_team_identifier "EXPECTED123" ""
}

# Verifies the ASR service may load only Apple code and its bundled runtime.
test_asr_service_policy() {
  local apple=$'/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation\n/usr/lib/libSystem.B.dylib'
  verify_asr_service_libraries "$apple"$'\n'"$asr_service_runtime_library"
  expect_failure verify_asr_service_libraries "$apple"
  expect_failure verify_asr_service_libraries "$apple"$'\n'"$asr_service_runtime_library"$'\n@rpath/libextra.dylib'
  verify_asr_service_rpaths $'/usr/lib/swift\n@executable_path/../Frameworks'
  expect_failure verify_asr_service_rpaths $'/usr/lib/swift\n/Users/builder/.build/asr_runtime'
}

test_release_version_validation
test_release_approval_validation
test_asr_service_policy
test_team_identifier_validation
print "build_release tests passed."
