#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ -f .env.local ]]; then
  set -a
  source .env.local
  set +a
fi

[[ -n "${HC_EXPECTED_TEAM_ID:-}" ]] || {
  print -u2 "HC_EXPECTED_TEAM_ID must be configured privately in .env.local."
  exit 1
}

derived_data="${HC_IOS_DERIVED_DATA_PATH:-$repo_root/.build/ios_probe_device}"

scripts/generate_ios_probe_project.sh
xcodebuild build -quiet \
  -project apps/ios_probe/VoiceProbe.xcodeproj \
  -scheme VoiceProbe \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$derived_data" \
  DEVELOPMENT_TEAM="$HC_EXPECTED_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic

app_bundle="$derived_data/Build/Products/Debug-iphoneos/VoiceProbe.app"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
signed_team="$(codesign -dv --verbose=4 "$app_bundle" 2>&1 \
  | awk -F= '/^TeamIdentifier=/{print $2}')"
[[ "$signed_team" == "$HC_EXPECTED_TEAM_ID" ]] || {
  print -u2 "Signed Team $signed_team does not match HC_EXPECTED_TEAM_ID."
  exit 1
}

print "$app_bundle"
