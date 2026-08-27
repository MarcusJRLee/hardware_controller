#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root="$(mktemp -d /tmp/voice_whisper_package_test.XXXXXX)"
trap 'rm -rf "$temporary_root"' EXIT
package="$temporary_root/package"

"$repo_root/scripts/prepare_ios_whisper_model_package.sh" "$package" >/dev/null
[[ "$(jq -r .runtime "$package/manifest.json")" == "whisper_cpp" ]]
[[ "$(jq -r .stage "$package/manifest.json")" == "asr" ]]
[[ "$(jq -r '.capabilities | join(",")' "$package/manifest.json")" == "file_asr" ]]

for relative_path in ggml-tiny.en.bin NOTICE.txt; do
  expected_bytes="$(jq -r --arg path "$relative_path" '.files[] | select(.path == $path) | .bytes' \
    "$package/manifest.json")"
  expected_sha256="$(jq -r --arg path "$relative_path" '.files[] | select(.path == $path) | .sha256' \
    "$package/manifest.json")"
  [[ "$(stat -f %z "$package/$relative_path")" == "$expected_bytes" ]]
  [[ "$(shasum -a 256 "$package/$relative_path" | cut -d ' ' -f 1)" == "$expected_sha256" ]]
done

if "$repo_root/scripts/prepare_ios_whisper_model_package.sh" "$package" >/dev/null 2>&1; then
  print -u2 "Package preparation must not overwrite an existing destination."
  exit 1
fi

print "iOS whisper Model-package preparation passed."
