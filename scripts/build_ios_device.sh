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

derived_data="${HC_IOS_DERIVED_DATA_PATH:-$repo_root/.build/ios_device}"

scripts/generate_ios_project.sh
xcodebuild build -quiet \
  -allowProvisioningUpdates \
  -project apps/ios/voice_input/VoiceInput.xcodeproj \
  -scheme VoiceInput \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$derived_data" \
  DEVELOPMENT_TEAM="$HC_EXPECTED_TEAM_ID" \
  CODE_SIGN_STYLE=Automatic

app_bundle="$derived_data/Build/Products/Debug-iphoneos/VoiceInput.app"
scripts/check_ios_system_capture_metadata.sh "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
linked_symbols="$(nm -gU "$app_bundle/VoiceInput" 2>/dev/null || true)"
linked_dependencies="$(otool -L "$app_bundle/VoiceInput" 2>/dev/null || true)"
if [[ -f "$app_bundle/VoiceInput.debug.dylib" ]]; then
  linked_symbols+="$(nm -gU "$app_bundle/VoiceInput.debug.dylib" 2>/dev/null || true)"
  linked_dependencies+="$(otool -L "$app_bundle/VoiceInput.debug.dylib" 2>/dev/null || true)"
fi
[[ "$linked_symbols" == *"_voice_model_package_validate_v2"* ]] || {
  print -u2 "The signed iOS app does not contain the Rust V2 Model-package validator."
  exit 1
}
[[ "$linked_symbols" == *"_voice_asr_model_resolve_v1"* ]] || {
  print -u2 "The signed iOS app does not contain the Rust ASR Model resolver."
  exit 1
}
[[ "$linked_dependencies" == *"whisper.framework/whisper"* ]] || {
  print -u2 "The signed iOS app does not link the pinned whisper.cpp runtime."
  exit 1
}
whisper_framework="$app_bundle/Frameworks/whisper.framework"
[[ -d "$whisper_framework" ]] || {
  print -u2 "The signed iOS app does not embed the pinned whisper.cpp runtime."
  exit 1
}
third_party_notices="$app_bundle/third_party_notices.txt"
[[ -f "$third_party_notices" ]] || {
  print -u2 "The signed iOS app does not contain its third-party notices."
  exit 1
}
grep -q "Copyright (c) 2023-2026 The ggml authors" "$third_party_notices" || {
  print -u2 "The signed iOS app does not contain the pinned whisper.cpp notice."
  exit 1
}
for extension_bundle in "$app_bundle"/PlugIns/*.appex; do
  extension_executable="$(plutil -extract CFBundleExecutable raw -o - \
    "$extension_bundle/Info.plist")"
  extension_binary="$extension_bundle/$extension_executable"
  extension_dependencies="$(otool -L "$extension_binary" 2>/dev/null || true)"
  extension_symbols="$(nm -gU "$extension_binary" 2>/dev/null || true)"
  extension_debug_binary="$extension_bundle/$extension_executable.debug.dylib"
  if [[ -f "$extension_debug_binary" ]]; then
    extension_dependencies+="$(otool -L "$extension_debug_binary" 2>/dev/null || true)"
    extension_symbols+="$(nm -gU "$extension_debug_binary" 2>/dev/null || true)"
  fi
  if [[ "$extension_dependencies" == *"whisper.framework/whisper"* \
    || "$extension_symbols" == *"_voice_whisper_"* \
    || "$extension_symbols" == *"_voice_asr_model_resolve_v1"* ]]; then
    print -u2 "$extension_bundle must not link model or ASR runtime code."
    exit 1
  fi
done
codesign --verify --strict --verbose=2 "$whisper_framework"
for signed_bundle in \
  "$app_bundle" \
  "$app_bundle"/Frameworks/VoiceInputShared.framework \
  "$whisper_framework" \
  "$app_bundle"/PlugIns/*.appex; do
  signed_team="$(codesign -dv --verbose=4 "$signed_bundle" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{print $2}')"
  [[ "$signed_team" == "$HC_EXPECTED_TEAM_ID" ]] || {
    print -u2 "$signed_bundle Team $signed_team does not match HC_EXPECTED_TEAM_ID."
    exit 1
  }
done

print "$app_bundle"
