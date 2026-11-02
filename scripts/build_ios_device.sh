#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

usage() {
  print "Usage: scripts/build_ios_device.sh [--config <development|local_qa>]"
}

build_configuration="Debug"
build_product_directory="Debug-iphoneos"
while (( $# > 0 )); do
  case "$1" in
    --config)
      (( $# >= 2 )) || {
        print -u2 "--config requires a value."
        exit 1
      }
      case "$2" in
        development)
          build_configuration="Debug"
          build_product_directory="Debug-iphoneos"
          ;;
        local_qa)
          build_configuration="Release"
          build_product_directory="Release-iphoneos"
          ;;
        *)
          print -u2 "Unsupported config '$2'. Use development or local_qa."
          exit 1
          ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown option: $1"
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -f .env.local ]]; then
  set -a
  source .env.local
  set +a
fi

# Voice Input may sign with a different team than the Mac app.
ios_team_id="${HC_IOS_TEAM_ID:-${HC_EXPECTED_TEAM_ID:-}}"
[[ -n "$ios_team_id" ]] || {
  print -u2 "HC_IOS_TEAM_ID or HC_EXPECTED_TEAM_ID must be configured privately in .env.local."
  exit 1
}

derived_data="${HC_IOS_DERIVED_DATA_PATH:-$repo_root/.build/ios_device}"

scripts/generate_ios_project.sh
xcodebuild build -quiet \
  -allowProvisioningUpdates \
  -project apps/ios/voice_input/VoiceInput.xcodeproj \
  -scheme VoiceInput \
  -configuration "$build_configuration" \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$derived_data" \
  DEVELOPMENT_TEAM="$ios_team_id" \
  CODE_SIGN_STYLE=Automatic

app_bundle="$derived_data/Build/Products/$build_product_directory/VoiceInput.app"
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
[[ "$linked_symbols" == *"_voice_asr_model_resolve_v2"* ]] || {
  print -u2 "The signed iOS app does not contain the Rust ASR Model resolver."
  exit 1
}
[[ "$linked_dependencies" == *"CTranscribe.framework/CTranscribe"* ]] || {
  print -u2 "The signed iOS app does not link the pinned transcribe.cpp runtime."
  exit 1
}
asr_framework="$app_bundle/Frameworks/CTranscribe.framework"
[[ -d "$asr_framework" ]] || {
  print -u2 "The signed iOS app does not embed the pinned transcribe.cpp runtime."
  exit 1
}
third_party_notices="$app_bundle/third_party_notices.txt"
[[ -f "$third_party_notices" ]] || {
  print -u2 "The signed iOS app does not contain its third-party notices."
  exit 1
}
grep -q "Copyright (c) 2023-2026 The ggml authors" "$third_party_notices" || {
  print -u2 "The signed iOS app does not contain the pinned ggml notice."
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
  if [[ "$extension_dependencies" == *"CTranscribe.framework/CTranscribe"* \
    || "$extension_symbols" == *"_voice_asr_context_"* \
    || "$extension_symbols" == *"_transcribe_"* \
    || "$extension_symbols" == *"_voice_asr_model_resolve_v2"* ]]; then
    print -u2 "$extension_bundle must not link model or ASR runtime code."
    exit 1
  fi
done
codesign --verify --strict --verbose=2 "$asr_framework"
for signed_bundle in \
  "$app_bundle" \
  "$app_bundle"/Frameworks/VoiceInputShared.framework \
  "$asr_framework" \
  "$app_bundle"/PlugIns/*.appex; do
  signed_team="$(codesign -dv --verbose=4 "$signed_bundle" 2>&1 \
    | awk -F= '/^TeamIdentifier=/{print $2}')"
  [[ "$signed_team" == "$ios_team_id" ]] || {
    print -u2 "$signed_bundle Team $signed_team does not match $ios_team_id."
    exit 1
  }
done

print "$app_bundle"
