#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# Prints one release failure and exits.
release_fail() {
  print -u2 "Release rejected: $1"
  exit 1
}

# Validates the source state before irreversible release evidence is created.
verify_source_state() {
  [[ "$(git rev-parse --show-toplevel)" == "$repo_root" ]] \
    || release_fail "the script is not running at the repository root."
  [[ "$(git branch --show-current)" == "main" ]] \
    || release_fail "the release must be built from main."

  [[ -z "$(git status --porcelain)" ]] \
    || release_fail "the worktree must be clean."

  local remote_main
  remote_main="$(
    git ls-remote --heads origin refs/heads/main \
      | awk '{print $1}'
  )"
  [[ -n "$remote_main" ]] \
    || release_fail "origin/main could not be resolved."
  [[ "$(git rev-parse HEAD)" == "$remote_main" ]] \
    || release_fail "main must exactly match remote origin/main."
}

# Validates a three-part numeric marketing version.
verify_release_version() {
  local version="$1"
  [[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
    || release_fail "CFBundleShortVersionString must use X.Y.Z."
}

# Requires the privately approved version to match packaged metadata exactly.
verify_release_approval() {
  local version="$1"
  local approved_version="$2"
  [[ -n "$approved_version" ]] \
    || release_fail "HC_RELEASE_APPROVED_VERSION must be set explicitly."
  [[ "$version" == "$approved_version" ]] \
    || release_fail "the approved version differs from packaging."
}

# Requires one exact signing Team without embedding maintainer metadata.
verify_team_identifier() {
  local actual="$1"
  local expected="$2"
  [[ -n "$expected" ]] \
    || release_fail "HC_EXPECTED_TEAM_ID must be configured privately."
  [[ "$actual" == "$expected" ]] \
    || release_fail "the signed Team identifier is unexpected."
}

# Validates the signed app's exact least-privilege entitlement set.
verify_entitlements() {
  local app_bundle="$1"
  local entitlement_file="$2"

  codesign -d --entitlements - --xml "$app_bundle" \
    >"$entitlement_file" 2>/dev/null
  plutil -lint "$entitlement_file" >/dev/null
  local key_count
  key_count="$(
    plutil -p "$entitlement_file" \
      | grep -Ec '^[[:space:]]+"[^"]+" =>'
  )"
  [[ "$key_count" == "1" ]] \
    || release_fail "the app must contain exactly one entitlement."
  [[ "$(
    plutil -extract 'com\.apple\.security\.device\.audio-input' \
      raw -o - "$entitlement_file"
  )" == "true" ]] \
    || release_fail "the audio-input entitlement is missing."
}

# Validates hardened signing metadata and Apple-only dynamic dependencies.
verify_binary_policy() {
  local app_bundle="$1"
  local binary="$app_bundle/Contents/MacOS/HardwareController"
  local signature_details
  signature_details="$(codesign -d --verbose=4 "$app_bundle" 2>&1)"

  print -r -- "$signature_details" \
    | grep -Eq '^Identifier=com\.longdevity\.hardwarecontroller$' \
    || release_fail "the signed bundle identifier is unexpected."
  print -r -- "$signature_details" \
    | grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
    || release_fail "hardened runtime is not enabled."
  local team_identifier
  team_identifier="$(
    print -r -- "$signature_details" \
      | sed -n 's/^TeamIdentifier=//p'
  )"
  verify_team_identifier \
    "$team_identifier" \
    "${HC_EXPECTED_TEAM_ID:-}"

  local unexpected_libraries
  unexpected_libraries="$(
    otool -L "$binary" \
      | awk 'NR > 1 {print $1}' \
      | grep -Ev '^(/System/Library/|/usr/lib/)' \
      || true
  )"
  [[ -z "$unexpected_libraries" ]] \
    || release_fail "the executable links a non-Apple runtime library."
}

# Verifies the app copied into the DMG is the signed release app.
verify_disk_image_contents() {
  local dmg_path="$1"
  local app_bundle="$2"
  local mount_point=".build/release_verification_mount"

  [[ ! -e "$mount_point" ]] \
    || release_fail "the release verification mount point already exists."
  mkdir -p "$mount_point"
  hdiutil attach \
    -readonly \
    -nobrowse \
    -mountpoint "$mount_point" \
    "$dmg_path" >/dev/null

  local mounted_app="$mount_point/Hardware Controller.app"
  local result=0
  codesign --verify --deep --strict --verbose=2 \
    "$mounted_app" || result=$?
  diff -qr "$app_bundle" "$mounted_app" >/dev/null \
    || result=1

  hdiutil detach "$mount_point" >/dev/null
  rmdir "$mount_point"
  [[ "$result" == "0" ]] \
    || release_fail "the DMG app does not match the signed release app."
}

# Emits the version-specific human and machine-verifiable release evidence.
write_release_evidence() {
  local evidence_path="$1"
  local release_version="$2"
  local build_number="$3"
  local source_commit="$4"
  local dmg_path="$5"
  local app_bundle="$6"
  local identity="$7"

  local dmg_hash
  local binary_hash
  local dmg_size
  local team_identifier
  dmg_hash="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"
  binary_hash="$(
    shasum -a 256 \
      "$app_bundle/Contents/MacOS/HardwareController" \
      | awk '{print $1}'
  )"
  dmg_size="$(stat -f '%z' "$dmg_path")"
  team_identifier="$(
    codesign -d --verbose=4 "$app_bundle" 2>&1 \
      | sed -n 's/^TeamIdentifier=//p'
  )"

  {
    print "# Hardware Controller $release_version release evidence"
    print
    print "| Field | Value |"
    print "| --- | --- |"
    print "| Source commit | \`$source_commit\` |"
    print "| Marketing version | $release_version |"
    print "| Build | $build_number |"
    print "| Architecture | arm64 |"
    print "| Minimum macOS | 15.0 |"
    print "| Signing identity | \`$identity\` |"
    print "| Team identifier | \`$team_identifier\` |"
    print "| Hardened runtime | Enabled |"
    print "| Runtime libraries | Apple system paths only |"
    print "| DMG bytes | $dmg_size |"
    print "| DMG SHA-256 | \`$dmg_hash\` |"
    print "| Executable SHA-256 | \`$binary_hash\` |"
    print
    print "The app passed strict deep signature verification, exact entitlement"
    print "verification, release build, DMG verification, and mounted-app equality."
  } >"$evidence_path"
}

# Runs the complete candidate build and verification workflow.
main() {
  [[ -n "${HC_CODE_SIGN_IDENTITY:-}" ]] \
    || release_fail "HC_CODE_SIGN_IDENTITY must name a valid identity."
  [[ "$HC_CODE_SIGN_IDENTITY" != "-" ]] \
    || release_fail "ad-hoc signing is not allowed."
  [[ -n "${HC_EXPECTED_TEAM_ID:-}" ]] \
    || release_fail "HC_EXPECTED_TEAM_ID must be configured privately."

  verify_source_state

  local app_bundle="dist/Hardware Controller.app"
  local release_directory=".build/Hardware Controller Release"
  local entitlement_file=".build/release_entitlements.plist"
  local release_version
  local build_number
  local source_commit
  release_version="$(
    plutil -extract CFBundleShortVersionString raw -o - \
      "packaging/Info.plist"
  )"
  build_number="$(
    plutil -extract CFBundleVersion raw -o - \
      "packaging/Info.plist"
  )"
  source_commit="$(git rev-parse HEAD)"
  verify_release_version "$release_version"
  verify_release_approval \
    "$release_version" \
    "${HC_RELEASE_APPROVED_VERSION:-}"

  local release_tag="v$release_version"
  local dmg_path="dist/Hardware Controller-$release_version.dmg"
  local evidence_path="dist/Hardware Controller-$release_version.release.md"

  git show-ref --verify --quiet "refs/tags/$release_tag" \
    && release_fail "$release_tag already exists locally."
  [[ -z "$(git ls-remote --tags origin "refs/tags/$release_tag")" ]] \
    || release_fail "$release_tag already exists remotely."

  swift format lint --recursive --strict \
    Package.swift Sources Tests
  xcrun clang-format --dry-run --Werror \
    Sources/HardwareControllerAudioBoundary/audio_engine_exception_boundary.m \
    Sources/HardwareControllerAudioBoundary/include/audio_engine_exception_boundary.h
  swift test
  HC_RUN_SQLITE_CONTENTION=1 swift test \
    --filter finalizationWaitsThroughTransientDatabaseContention
  HC_RUN_HID_PERFORMANCE=1 swift test \
    --filter tenThousandTransitionSoakMeetsDispatchBudget
  zsh -n scripts/*.sh
  plutil -lint packaging/*.plist >/dev/null

  "$repo_root/scripts/build_app.sh"

  rm -rf "$release_directory"
  rm -f "$dmg_path"
  rm -f "$evidence_path"
  mkdir -p "$release_directory"

  ditto "$app_bundle" \
    "$release_directory/Hardware Controller.app"
  ln -s /Applications "$release_directory/Applications"

  hdiutil create \
    -volname "Hardware Controller" \
    -srcfolder "$release_directory" \
    -format UDZO \
    -ov \
    "$dmg_path" >/dev/null

  hdiutil verify "$dmg_path" >/dev/null
  codesign --verify --deep --strict --verbose=2 "$app_bundle"
  verify_entitlements "$app_bundle" "$entitlement_file"
  verify_binary_policy "$app_bundle"

  [[ "$(
    plutil -extract CFBundleShortVersionString raw -o - \
      "$app_bundle/Contents/Info.plist"
  )" == "$release_version" ]] \
    || release_fail "the app marketing version differs from packaging."
  [[ "$(
    plutil -extract CFBundleVersion raw -o - \
      "$app_bundle/Contents/Info.plist"
  )" == "$build_number" ]] \
    || release_fail "the app build number differs from packaging."
  file "$app_bundle/Contents/MacOS/HardwareController" \
    | grep -Fq 'Mach-O 64-bit executable arm64' \
    || release_fail "the executable is not thin arm64."
  otool -l "$app_bundle/Contents/MacOS/HardwareController" \
    | grep -A 4 'LC_BUILD_VERSION' \
    | grep -Eq 'minos 15\.0' \
    || release_fail "the executable minimum is not macOS 15.0."

  verify_disk_image_contents "$dmg_path" "$app_bundle"
  write_release_evidence \
    "$evidence_path" \
    "$release_version" \
    "$build_number" \
    "$source_commit" \
    "$dmg_path" \
    "$app_bundle" \
    "$HC_CODE_SIGN_IDENTITY"

  print "$dmg_path"
  print "$evidence_path"
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  main "$@"
fi
