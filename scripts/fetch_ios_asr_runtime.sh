#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_root="$repo_root/.build/ios_asr_runtime"
archive="$output_root/whisper-b4938-xcframework.zip"
xcframework="$output_root/build-apple/whisper.xcframework"
source_url="https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip"
archive_sha256="dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"

mkdir -p "$output_root"
if [[ ! -f "$archive" ]]; then
  command -v curl >/dev/null || {
    print -u2 "curl is required to fetch the pinned iOS ASR runtime."
    exit 1
  }
  temporary_archive="$archive.partial"
  rm -f "$temporary_archive"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$temporary_archive" "$source_url"
  mv "$temporary_archive" "$archive"
fi

actual_archive_sha256="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
[[ "$actual_archive_sha256" == "$archive_sha256" ]] || {
  print -u2 "Pinned whisper.cpp archive digest mismatch."
  exit 1
}

if [[ ! -d "$xcframework" ]]; then
  extraction_root="$output_root/extracting"
  rm -rf "$extraction_root"
  mkdir -p "$extraction_root"
  ditto -x -k "$archive" "$extraction_root"
  mv "$extraction_root/build-apple" "$output_root/build-apple"
  rmdir "$extraction_root"
fi

verify_file() {
  local expected_sha256="$1"
  local relative_path="$2"
  local actual_sha256
  actual_sha256="$(shasum -a 256 "$xcframework/$relative_path" | cut -d ' ' -f 1)"
  [[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "Pinned whisper.cpp file digest mismatch: $relative_path"
    exit 1
  }
}

verify_file \
  "32b3cf620950807bae05311cf65ab443c789ca748c1b17185f9db0aa501f91c4" \
  "ios-arm64/whisper.framework/whisper"
verify_file \
  "b28cf7d2cb2be874c96deb8e468f5f3146ab39c273151570a8d66df61bd2e428" \
  "ios-arm64_x86_64-simulator/whisper.framework/whisper"
verify_file \
  "a7d19f7feb5be52426628ff07e0602de28a30dc4312d0d0603e1e536753f76dd" \
  "ios-arm64/whisper.framework/Headers/whisper.h"
verify_file \
  "48dbcc84804ecc7f47b209ae45c63dea49903dd7985843466dcb37286112b1c5" \
  "Info.plist"

print "$xcframework"
