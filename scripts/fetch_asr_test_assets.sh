#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/.build/asr_test_assets"
mkdir -p "$output_root"

# Every model file is fetched from an immutable Hugging Face revision.
whisper_revision="https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/9dd46e00ef0577e354e658c07b3ac5580e9cd211"
speech_revision="https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/a9b2d61c20ae4ddf3644edb34969e8185a485448"

fetch_verified() {
  local url="$1"
  local expected_sha256="$2"
  local output="$output_root/$3"
  if [[ ! -f "$output" ]]; then
    local partial="$output.partial"
    rm -f "$partial"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
      --output "$partial" "$url"
    mv "$partial" "$output"
  fi
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$output" | cut -d ' ' -f 1)"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "Pinned ASR test-asset digest mismatch: $output"
    exit 1
  }
  print "$output"
}

fetch_verified "$whisper_revision/whisper-tiny.en-Q8_0.gguf" \
  "e8c9b73c06344307d8b346e07fbe93dd88d894627854bcff31523f1ce44394fa" \
  "whisper-tiny.en-Q8_0.gguf"
fetch_verified "https://raw.githubusercontent.com/ggml-org/whisper.cpp/b4938/samples/jfk.wav" \
  "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e" \
  "jfk.wav"
fetch_verified "$speech_revision/silero-vad-v6.2-F32.gguf" \
  "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6" \
  "silero-vad-v6.2-F32.gguf"
fetch_verified "$whisper_revision/LICENSE" \
  "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30" \
  "whisper-tiny.en-LICENSE.txt"
fetch_verified "$whisper_revision/NOTICE" \
  "bbd3f17bf590555974378095ee6389411f45f02f39c84511691b15bd84a49d20" \
  "whisper-tiny.en-NOTICE.txt"
fetch_verified "$speech_revision/LICENSE" \
  "2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b" \
  "silero-vad-v6.2-LICENSE.txt"
fetch_verified "$speech_revision/NOTICE" \
  "f1ea43096a23b40d4b14fcf131586710035444e69e35051c5d83c60725b50555" \
  "silero-vad-v6.2-NOTICE.txt"
