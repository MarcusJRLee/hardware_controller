#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift format lint --recursive --strict \
  Package.swift Sources Tests
xcrun clang-format --dry-run --Werror \
  Sources/HardwareControllerAudioBoundary/audio_engine_exception_boundary.m \
  Sources/HardwareControllerAudioBoundary/include/audio_engine_exception_boundary.h \
  Sources/voice_ffi_bridge/include/voice_ffi_bridge.h \
  Sources/voice_ffi_bridge/voice_ffi_bridge.c \
  Sources/voice_whisper_bridge/include/voice_whisper_bridge.h \
  Sources/voice_whisper_bridge/voice_whisper_bridge.c \
  crates/voice_ffi/include/voice_ffi.h \
  Tests/voice_ffi/retention_smoke.c \
  Tests/voice_whisper_bridge_tests/voice_whisper_bridge_test.c
zsh -n scripts/*.sh
scripts/check_rust.sh
scripts/check_voice_whisper_bridge.sh
scripts/prepare_ios_whisper_model_package_test.sh
swift test
HC_RUN_SQLITE_CONTENTION=1 swift test \
  --filter finalizationWaitsThroughTransientDatabaseContention
HC_RUN_HID_PERFORMANCE=1 swift test \
  --filter tenThousandTransitionSoakMeetsDispatchBudget
swift build -c release --product HardwareController
binary_directory="$(swift build -c release --show-bin-path)"
linked_symbols="$(nm -gU "$binary_directory/HardwareController")"
if [[ "$linked_symbols" != *"_voice_history_archive_validate_v1"* \
  || "$linked_symbols" != *"_voice_model_package_validate_v2"* \
  || "$linked_symbols" != *"_voice_asr_model_resolve_v1"* ]]; then
  print -u2 "The macOS app does not contain its active portable Voice validators."
  exit 1
fi
scripts/build_release_test.sh
scripts/notarize_release_test.sh
