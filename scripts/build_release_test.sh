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

# Verifies exact private Team matching without embedding a real identifier.
test_team_identifier_validation() {
  verify_team_identifier "EXPECTED123" "EXPECTED123"
  expect_failure verify_team_identifier "OTHER123" "EXPECTED123"
  expect_failure verify_team_identifier "EXPECTED123" ""
}

test_release_version_validation
test_team_identifier_validation
print "build_release tests passed."
