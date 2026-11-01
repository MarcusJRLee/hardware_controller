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

assets=("${(@f)$("$repo_root/scripts/fetch_asr_test_assets.sh")}")
cp "${assets[1]}" "$staging/whisper-tiny.en-Q8_0.gguf"
cp "${assets[3]}" "$staging/silero-vad-v6.2-F32.gguf"
{
  print "Whisper Tiny English with Silero speech detection for local Voice Input."
  print
  print "Runtime source: https://github.com/handy-computer/transcribe.cpp"
  print
  print "== whisper-tiny.en-Q8_0.gguf (Apache-2.0) =="
  cat "${assets[5]}"
  print
  cat "${assets[4]}"
  print
  print "== silero-vad-v6.2-F32.gguf (MIT) =="
  cat "${assets[7]}"
  print
  cat "${assets[6]}"
} >"$staging/NOTICE.txt"

file_entry() {
  local relative_path="$1"
  local role="$2"
  print -r -- "    {
      \"path\": \"$relative_path\",
      \"role\": \"$role\",
      \"bytes\": $(stat -f %z "$staging/$relative_path"),
      \"sha256\": \"$(shasum -a 256 "$staging/$relative_path" | cut -d ' ' -f 1)\"
    }"
}

cat >"$staging/manifest.json" <<MANIFEST
{
  "schema_version": 1,
  "package_id": "com.longdevity.asr.whisper_tiny_en",
  "version": "9dd46e0-q8_0",
  "display_name": "Whisper Tiny English",
  "runtime": "transcribe_cpp",
  "stage": "asr",
  "capabilities": ["file_asr"],
  "languages": ["en-US"],
  "license": {
    "spdx_expression": "Apache-2.0 AND MIT",
    "notice_file": "NOTICE.txt",
    "source_url": "https://huggingface.co/handy-computer/whisper-tiny.en-gguf"
  },
  "resources": {
    "minimum_memory_bytes": 268435456,
    "recommended_memory_bytes": 536870912
  },
  "files": [
$(file_entry whisper-tiny.en-Q8_0.gguf model),
$(file_entry silero-vad-v6.2-F32.gguf speech_detection),
$(file_entry NOTICE.txt notice)
  ]
}
MANIFEST

mv "$staging" "$output"
trap - EXIT
print "$output"
