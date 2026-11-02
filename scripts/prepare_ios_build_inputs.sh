#!/bin/zsh

# Builds every ignored input the iOS project references, so project
# generation and CI analysis builds cannot drift apart.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

scripts/build_ios_rust_ffi.sh
scripts/fetch_asr_runtime.sh
# The app bundles this starter so a fresh install dictates without Mac-side
# preparation; regenerating keeps it identical to the pinned assets.
starter_model=.build/ios_voice_input/starter_asr_model
rm -rf "$starter_model"
scripts/prepare_ios_asr_model_package.sh "$starter_model" >/dev/null
