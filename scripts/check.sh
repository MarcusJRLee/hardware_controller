#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

swift format lint --recursive --strict \
  Package.swift Sources Tests
# Every tracked C and Objective-C source is formatted; no hand-kept list.
c_sources=("${(@f)$(git ls-files '*.c' '*.h' '*.m')}")
xcrun clang-format --dry-run --Werror "${c_sources[@]}"
scripts/check_fast.sh
scripts/smoke_app_test.sh
scripts/install_app_test.sh
scripts/install_ios_test.sh
scripts/check_rust.sh
scripts/check_voice_asr_bridge.sh
scripts/prepare_ios_asr_model_package_test.sh
# Identical flags on every invocation share one build instead of rebuilding.
swift_flags=(-Xswiftc -warnings-as-errors)
swift test "${swift_flags[@]}"
HC_RUN_SQLITE_CONTENTION=1 swift test "${swift_flags[@]}" \
  --filter finalizationWaitsThroughTransientDatabaseContention
HC_RUN_HID_PERFORMANCE=1 swift test "${swift_flags[@]}" \
  --filter tenThousandTransitionSoakMeetsDispatchBudget
swift build -c release --product HardwareController "${swift_flags[@]}"
binary_directory="$(swift build -c release "${swift_flags[@]}" --show-bin-path)"
linked_symbols="$(nm -gU "$binary_directory/HardwareController")"
if [[ "$linked_symbols" != *"_voice_history_archive_validate_v1"* \
  || "$linked_symbols" != *"_voice_model_package_validate_v2"* \
  || "$linked_symbols" != *"_voice_asr_model_resolve_v2"* ]]; then
  print -u2 "The macOS app does not contain its active portable Voice validators."
  exit 1
fi
scripts/build_release_test.sh
scripts/notarize_release_test.sh
