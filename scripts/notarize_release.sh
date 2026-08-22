#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$repo_root/scripts/build_release.sh"

# Prints one public-distribution failure and exits.
public_release_fail() {
  print -u2 "Public release rejected: $1"
  exit 1
}

# Requires the built app to use a Developer ID Application identity.
verify_developer_id_authority() {
  local signature_details="$1"
  print -r -- "$signature_details" \
    | grep -Eq '^Authority=Developer ID Application:' \
    || public_release_fail "the app is not signed with Developer ID Application."
  print -r -- "$signature_details" \
    | grep -Eq '^Timestamp=' \
    || public_release_fail "the Developer ID signature has no secure timestamp."
}

# Requires an accepted response from Apple's notary service.
verify_notarization_status() {
  local notary_status="$1"
  [[ "$notary_status" == "Accepted" ]] \
    || public_release_fail "Apple notarization did not return Accepted."
}

# Notarizes and validates the exact approved DMG built by build_release.sh.
main() {
  cd "$repo_root"
  verify_source_state

  local release_version
  release_version="$(
    plutil -extract CFBundleShortVersionString raw -o - \
      "packaging/Info.plist"
  )"
  verify_release_version "$release_version"
  verify_release_approval \
    "$release_version" \
    "${HC_RELEASE_APPROVED_VERSION:-}"
  [[ -n "${HC_NOTARYTOOL_PROFILE:-}" ]] \
    || public_release_fail "HC_NOTARYTOOL_PROFILE must name a Keychain profile."

  local app_bundle="dist/Hardware Controller.app"
  local dmg_path="dist/Hardware Controller-$release_version.dmg"
  local evidence_path="dist/Hardware Controller-$release_version.release.md"
  local response_path=".build/notarization_response.plist"
  local log_path=".build/notarization_log.json"
  [[ -d "$app_bundle" ]] \
    || public_release_fail "the approved app bundle has not been built."
  [[ -f "$dmg_path" ]] \
    || public_release_fail "the approved DMG has not been built."
  [[ -f "$evidence_path" ]] \
    || public_release_fail "release evidence is missing."
  local source_commit
  source_commit="$(git rev-parse HEAD)"
  grep -Fq "| Source commit | \`$source_commit\` |" "$evidence_path" \
    || public_release_fail "release evidence does not match the current commit."
  grep -Fq "| Marketing version | $release_version |" "$evidence_path" \
    || public_release_fail "release evidence does not match the approved version."
  ! grep -Eq '^## Notarization evidence$' "$evidence_path" \
    || public_release_fail "notarization evidence already exists."

  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  local signature_details
  signature_details="$(codesign -d --verbose=4 "$app_bundle" 2>&1)"
  verify_developer_id_authority "$signature_details"

  rm -f "$response_path" "$log_path"
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$HC_NOTARYTOOL_PROFILE" \
    --wait \
    --output-format plist \
    >"$response_path"
  plutil -lint "$response_path" >/dev/null

  local submission_id
  local notarization_status
  submission_id="$(plutil -extract id raw -o - "$response_path")"
  notarization_status="$(plutil -extract status raw -o - "$response_path")"
  if [[ "$notarization_status" != "Accepted" ]]; then
    xcrun notarytool log "$submission_id" \
      --keychain-profile "$HC_NOTARYTOOL_PROFILE" \
      "$log_path" || true
  fi
  verify_notarization_status "$notarization_status"

  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  hdiutil verify "$dmg_path" >/dev/null
  spctl -a -t open \
    --context context:primary-signature \
    -v "$dmg_path"
  verify_disk_image_contents "$dmg_path" "$app_bundle"

  local dmg_hash
  dmg_hash="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
  {
    print
    print "## Notarization evidence"
    print
    print "The earlier DMG hash records the pre-notarization container. The hash"
    print "below identifies the stapled distributable artifact."
    print
    print "| Field | Value |"
    print "| --- | --- |"
    print "| Apple status | Accepted |"
    print "| Submission | \`$submission_id\` |"
    print "| Ticket stapled | Yes |"
    print "| Gatekeeper assessment | Passed |"
    print "| Notarized DMG SHA-256 | \`$dmg_hash\` |"
  } >>"$evidence_path"

  print "$dmg_path"
  print "$evidence_path"
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  main "$@"
fi
