#!/bin/zsh

# The one supported way to put current source in /Applications: build with the
# private Apple Development identity, verify the bundle, replace the single
# canonical copy, verify it again, then prove the installed app launches.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# Reuses the release signature policy without running the release.
source scripts/build_release.sh

canonical="${HC_INSTALL_PATH:-/Applications/Hardware Controller.app}"
bundle_id="com.longdevity.hardwarecontroller"
built="${HC_BUILT_APP:-dist/Hardware Controller.app}"

release_fail() {
  print -u2 "Install rejected: $1"
  exit 1
}

# Loads ignored signing values and requires an unexpired Apple Development identity.
load_signing_environment() {
  local env_file="${HC_ENV_FILE:-.env.local}"
  [[ -f "$env_file" ]] || release_fail "$env_file is missing; copy .env.example."
  set -a
  source "$env_file"
  set +a
  [[ -n "${HC_CODE_SIGN_IDENTITY:-}" && "$HC_CODE_SIGN_IDENTITY" != "-" ]] \
    || release_fail "HC_CODE_SIGN_IDENTITY must name an Apple Development identity."
  [[ -n "${HC_EXPECTED_TEAM_ID:-}" ]] \
    || release_fail "HC_EXPECTED_TEAM_ID must be set in .env.local."
  # `-v` lists only valid identities, so an expired certificate fails here.
  security find-identity -v -p codesigning | grep -Fq -- "$HC_CODE_SIGN_IDENTITY" \
    || release_fail "no valid signing identity matches HC_CODE_SIGN_IDENTITY; renew it in Xcode → Settings → Accounts."
}

# Applies the release signature policy plus unchanged version metadata.
verify_bundle() {
  local bundle="$1"
  codesign --verify --deep --strict "$bundle" 2>/dev/null \
    || release_fail "$bundle has an invalid signature."
  local entitlements
  entitlements="$(mktemp)"
  verify_entitlements "$bundle" "$entitlements"
  rm -f "$entitlements"
  verify_binary_policy "$bundle"
  local key
  for key in CFBundleShortVersionString CFBundleVersion; do
    [[ "$(plutil -extract "$key" raw -o - "$bundle/Contents/Info.plist")" \
      == "$(plutil -extract "$key" raw -o - packaging/Info.plist)" ]] \
      || release_fail "$key in $bundle differs from packaging/Info.plist."
  done
}

# Asks the running app to quit and waits; never force-kills a live session.
quit_running_app() {
  pgrep -f "Hardware Controller.app/Contents/MacOS/HardwareController" >/dev/null || return 0
  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do
    pgrep -f "Hardware Controller.app/Contents/MacOS/HardwareController" >/dev/null || return 0
    sleep 0.5
  done
  release_fail "Hardware Controller did not quit; finish any active session and retry."
}

# Stages beside the destination so the final swap is one rename.
replace_canonical() {
  local staging="${canonical:h}/.${canonical:t}.installing"
  rm -rf "$staging"
  ditto "$built" "$staging"
  rm -rf "$canonical"
  mv "$staging" "$canonical"
}

main() {
  load_signing_environment
  scripts/build_app.sh >/dev/null
  verify_bundle "$built"
  quit_running_app
  replace_canonical
  verify_bundle "$canonical"
  cmp -s "$built/Contents/MacOS/HardwareController" \
    "$canonical/Contents/MacOS/HardwareController" \
    || release_fail "the installed executable differs from the verified build."
  scripts/smoke_app.sh "$canonical" --installed
  print "Installed and launched $canonical ($(plutil -extract CFBundleShortVersionString raw -o - packaging/Info.plist) build $(plutil -extract CFBundleVersion raw -o - packaging/Info.plist))."
}

if [[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]]; then
  main "$@"
fi
