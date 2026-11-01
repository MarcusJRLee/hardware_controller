#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root="$(mktemp -d /tmp/voice_asr_package_test.XXXXXX)"
trap 'rm -rf "$temporary_root"' EXIT
package="$temporary_root/package"

"$repo_root/scripts/prepare_ios_asr_model_package.sh" "$package" >/dev/null
manifest="$package/manifest.json"
[[ "$(jq -r .runtime "$manifest")" == "transcribe_cpp" ]]
[[ "$(jq -r .stage "$manifest")" == "asr" ]]
[[ "$(jq -r '.capabilities | join(",")' "$manifest")" == "file_asr" ]]
[[ "$(jq -r '[.files[].role] | join(",")' "$manifest")" == "model,speech_detection,notice" ]]
grep -q "Silero Team" "$package/NOTICE.txt"

for relative_path in whisper-tiny.en-Q8_0.gguf silero-vad-v6.2-F32.gguf NOTICE.txt; do
  expected_bytes="$(jq -r --arg path "$relative_path" '.files[] | select(.path == $path) | .bytes' \
    "$manifest")"
  expected_sha256="$(jq -r --arg path "$relative_path" '.files[] | select(.path == $path) | .sha256' \
    "$manifest")"
  [[ "$(stat -f %z "$package/$relative_path")" == "$expected_bytes" ]]
  [[ "$(shasum -a 256 "$package/$relative_path" | cut -d ' ' -f 1)" == "$expected_sha256" ]]
done

if "$repo_root/scripts/prepare_ios_asr_model_package.sh" "$package" >/dev/null 2>&1; then
  print -u2 "Package preparation must not overwrite an existing destination."
  exit 1
fi

print "iOS ASR Model-package preparation passed."
