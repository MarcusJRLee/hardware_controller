#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

cargo build --package voice_ffi --release --locked

library="target/release/libvoice_ffi.a"
digest="$(shasum -a 256 "$library" | awk '{print $1}')"
stamp="Sources/hardware_controller_voice_ffi/voice_ffi_build_stamp.generated.swift"
contents="internal let voiceFFIBuildDigest =
  \"$digest\""
if [[ ! -f "$stamp" || "$(<"$stamp")" != "$contents" ]]; then
  print -r -- "$contents" >"$stamp"
fi
