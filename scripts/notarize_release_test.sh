#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/notarize_release.sh"

# Runs one command and requires it to fail.
expect_public_failure() {
  if ("$@") >/dev/null 2>&1; then
    print -u2 "Expected failure: $*"
    exit 1
  fi
}

# Verifies Developer ID and secure timestamp requirements.
test_developer_id_authority_validation() {
  verify_developer_id_authority $'Authority=Developer ID Application: Example (TEAM)\nTimestamp=Aug 22, 2026'
  expect_public_failure verify_developer_id_authority \
    $'Authority=Apple Development: Example (TEAM)\nTimestamp=Aug 22, 2026'
  expect_public_failure verify_developer_id_authority \
    'Authority=Developer ID Application: Example (TEAM)'
}

# Verifies only an accepted notarization result may continue.
test_notarization_status_validation() {
  verify_notarization_status "Accepted"
  expect_public_failure verify_notarization_status "Invalid"
  expect_public_failure verify_notarization_status ""
}

test_developer_id_authority_validation
test_notarization_status_validation
print "notarize_release tests passed."
