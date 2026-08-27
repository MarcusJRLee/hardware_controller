#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

command -v xcodegen >/dev/null || {
  print -u2 "xcodegen is required to generate the iOS project."
  exit 1
}

scripts/build_ios_rust_ffi.sh
scripts/fetch_ios_asr_runtime.sh

xcodegen generate \
  --spec apps/ios/voice_input/project.yml \
  --project apps/ios/voice_input
