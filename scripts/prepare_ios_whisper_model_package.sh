#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$repo_root/.build/ios_whisper_tiny_en_package}"
[[ ! -e "$output" ]] || {
  print -u2 "Model-package output already exists: $output"
  exit 1
}
output_parent="$(dirname "$output")"
output_name="$(basename "$output")"
mkdir -p "$output_parent"
staging="$(mktemp -d "$output_parent/.${output_name}.partial.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

assets=("${(@f)$("$repo_root/scripts/fetch_ios_asr_test_assets.sh")}")
model_source="${assets[1]}"
cp "$model_source" "$staging/ggml-tiny.en.bin"
cat >"$staging/NOTICE.txt" <<'EOF'
Whisper tiny.en model package for local Voice Input inference.

Model source: https://huggingface.co/ggerganov/whisper.cpp
Runtime source: https://github.com/ggml-org/whisper.cpp
Whisper model code and weights are available under the MIT License.
EOF

model_bytes="$(stat -f %z "$staging/ggml-tiny.en.bin")"
model_sha256="$(shasum -a 256 "$staging/ggml-tiny.en.bin" | cut -d ' ' -f 1)"
notice_bytes="$(stat -f %z "$staging/NOTICE.txt")"
notice_sha256="$(shasum -a 256 "$staging/NOTICE.txt" | cut -d ' ' -f 1)"
cat >"$staging/manifest.json" <<EOF
{
  "schema_version": 1,
  "package_id": "com.longdevity.whisper.tiny_en",
  "version": "b4938",
  "display_name": "Whisper Tiny English",
  "runtime": "whisper_cpp",
  "stage": "asr",
  "capabilities": ["file_asr"],
  "languages": ["en-US"],
  "license": {
    "spdx_expression": "MIT",
    "notice_file": "NOTICE.txt",
    "source_url": "https://huggingface.co/ggerganov/whisper.cpp"
  },
  "resources": {
    "minimum_memory_bytes": 268435456,
    "recommended_memory_bytes": 536870912
  },
  "files": [
    {
      "path": "ggml-tiny.en.bin",
      "role": "model",
      "bytes": $model_bytes,
      "sha256": "$model_sha256"
    },
    {
      "path": "NOTICE.txt",
      "role": "notice",
      "bytes": $notice_bytes,
      "sha256": "$notice_sha256"
    }
  ]
}
EOF

mv "$staging" "$output"
trap - EXIT
print "$output"
