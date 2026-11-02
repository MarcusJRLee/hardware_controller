#!/bin/zsh

# Proves an installed app's speech service end to end (decision 0060): load a
# package through XPC, decode real speech, measure IPC overhead, crash the
# service mid-decode, and recover. launchd resolves the service only inside a
# signed bundle, so this runs on installs, not in CI.
# Usage: scripts/check_speech_engine.sh [APP]

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

app="${1:-/Applications/Hardware Controller.app}"
assets=("${(@f)$(scripts/fetch_asr_test_assets.sh)}")
package="$repo_root/.build/speech_engine_check_package"
[[ -d "$package" ]] || scripts/prepare_ios_asr_model_package.sh "$package" >/dev/null
"$app/Contents/MacOS/HardwareController" --verify-speech-engine "$package" "${assets[2]}"
