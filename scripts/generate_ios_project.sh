#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v xcodegen >/dev/null || {
  print -u2 "xcodegen is required to generate the iOS project."
  exit 1
}

scripts/build_ios_rust_ffi.sh
scripts/fetch_asr_runtime.sh
# The app bundles this starter so a fresh install dictates without Mac-side
# preparation; regenerating keeps it identical to the pinned assets.
starter_model=.build/ios_voice_input/starter_asr_model
rm -rf "$starter_model"
scripts/prepare_ios_asr_model_package.sh "$starter_model" >/dev/null

xcodegen generate \
  --spec apps/ios/voice_input/project.yml \
  --project apps/ios/voice_input
