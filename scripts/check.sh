#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift format lint --recursive --strict \
  Package.swift Sources Tests
xcrun clang-format --dry-run --Werror \
  Sources/HardwareControllerAudioBoundary/audio_engine_exception_boundary.m \
  Sources/HardwareControllerAudioBoundary/include/audio_engine_exception_boundary.h \
  crates/voice_ffi/include/voice_ffi.h \
  Tests/voice_ffi/retention_smoke.c
zsh -n scripts/*.sh
scripts/check_rust.sh
swift test
HC_RUN_SQLITE_CONTENTION=1 swift test \
  --filter finalizationWaitsThroughTransientDatabaseContention
HC_RUN_HID_PERFORMANCE=1 swift test \
  --filter tenThousandTransitionSoakMeetsDispatchBudget
swift build -c release --product HardwareController
scripts/build_release_test.sh
scripts/notarize_release_test.sh
