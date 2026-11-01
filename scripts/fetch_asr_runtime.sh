#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/.build/asr_runtime"
archive="$output_root/transcribe-cpp-v0.4.1-xcframework.zip"
xcframework="$output_root/TranscribeCpp.xcframework"
source_url="https://github.com/handy-computer/transcribe.cpp/releases/download/v0.4.1/TranscribeCpp.xcframework.zip"
archive_sha256="fb5646e564036a6c49659e3efcf72eb567af20da31b8569045c9a08181d35126"

mkdir -p "$output_root"
if [[ ! -f "$archive" ]]; then
  command -v curl >/dev/null || {
    print -u2 "curl is required to fetch the pinned ASR runtime."
    exit 1
  }
  temporary_archive="$archive.partial"
  rm -f "$temporary_archive"
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --output "$temporary_archive" "$source_url"
  mv "$temporary_archive" "$archive"
fi

actual_archive_sha256="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual_archive_sha256" == "$archive_sha256" ]] || {
  print -u2 "Pinned transcribe.cpp archive digest mismatch."
  exit 1
}

if [[ ! -d "$xcframework" ]]; then
  extraction_root="$output_root/extracting"
  rm -rf "$extraction_root"
  mkdir -p "$extraction_root"
  ditto -x -k "$archive" "$extraction_root"
  mv "$extraction_root/TranscribeCpp.xcframework" "$xcframework"
  rmdir "$extraction_root"
fi

verify_file() {
  local expected_sha256="$1"
  local relative_path="$2"
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$xcframework/$relative_path" | cut -d ' ' -f 1)"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "Pinned transcribe.cpp file digest mismatch: $relative_path"
    exit 1
  }
}

verify_file \
  "ef872bea777ea6350929e8d99f0bcdf2090878701d68665765d1abe0b6d3b116" \
  "ios-arm64/CTranscribe.framework/CTranscribe"
verify_file \
  "db92ed3d73b0e45bb495590e407d8cfce11e5f71c7b21d8f021309bc813ce40a" \
  "ios-arm64_x86_64-simulator/CTranscribe.framework/CTranscribe"
verify_file \
  "4abd84c31bfe4d902d59a3db28167df79437c448454488bf0880223015219763" \
  "macos-arm64_x86_64/CTranscribe.framework/Versions/A/CTranscribe"
verify_file \
  "6eeff40fa7d9d3b17eb021170fda4046b5f54794ddfe4295bcf62bbc6015f652" \
  "ios-arm64/CTranscribe.framework/Headers/transcribe.h"
verify_file \
  "8dec48a2d6c6b72f977011813fb5aee333815724322b65dbdc293235b99b11a3" \
  "ios-arm64/CTranscribe.framework/Headers/vad.h"
verify_file \
  "8650d06c40e811cb4bc979abcffe6ac5a2951788b778f95558b7ad44d48cf7e7" \
  "Info.plist"
verify_file \
  "86a53633b56f6b029d3cb42158bcc7aac0cdff898aceb13e83b93e368bbc4ac6" \
  "LICENSE"

print "$xcframework"
