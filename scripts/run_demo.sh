#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

scripts/build_rust_ffi.sh
swift run HardwareController --demo
