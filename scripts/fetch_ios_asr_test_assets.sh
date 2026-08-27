#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/.build/ios_asr_test_assets"
model="$output_root/ggml-tiny.en.bin"
audio="$output_root/jfk.wav"
mkdir -p "$output_root"

fetch_verified() {
  local url="$1"
  local expected_sha256="$2"
  local output="$3"
  if [[ ! -f "$output" ]]; then
    local partial="$output.partial"
    rm -f "$partial"
    curl --fail --location --proto '=https' --tlsv1.2 \
      --output "$partial" "$url"
    mv "$partial" "$output"
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$output" | cut -d ' ' -f 1)"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "Pinned ASR test-asset digest mismatch: $output"
    exit 1
  }
}

fetch_verified \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin" \
  "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f" \
  "$model"
fetch_verified \
  "https://raw.githubusercontent.com/ggml-org/whisper.cpp/b4938/samples/jfk.wav" \
  "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e" \
  "$audio"

print "$model"
print "$audio"
