#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

cargo fmt --all --check
cargo clippy --workspace --all-targets --locked
cargo test --workspace --locked
cargo build --package voice_ffi --release --locked

smoke_binary="target/voice_ffi_retention_smoke"
if [[ "$(uname -s)" == "Darwin" ]]; then
  xcrun clang \
    -std=c17 \
    -Wall \
    -Wextra \
    -Werror \
    -I crates/voice_ffi/include \
    Tests/voice_ffi/retention_smoke.c \
    target/release/libvoice_ffi.a \
    -o "$smoke_binary"
else
  cc \
    -std=c17 \
    -Wall \
    -Wextra \
    -Werror \
    -I crates/voice_ffi/include \
    Tests/voice_ffi/retention_smoke.c \
    target/release/libvoice_ffi.a \
    -ldl \
    -lpthread \
    -lm \
    -o "$smoke_binary"
fi
"$smoke_binary" \
  "Tests/cuj/voice_model_package_v1/valid" \
  "Tests/cuj/voice_history_archive_v1/valid"
