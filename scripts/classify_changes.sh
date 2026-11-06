#!/bin/zsh

# Decides which CI lanes a change needs so expensive macOS jobs run only when
# their inputs changed. Prints GitHub output lines (`lane=true|false`).
# Usage: classify_changes.sh [<base-sha>]
#   Without a base (push, schedule, manual), every lane runs.
#   HC_CHANGED_FILES (newline-separated) replaces the git diff, for tests.

set -euo pipefail

base="${1:-}"
lanes=(macos ios)
typeset -A lane
for name in "${lanes[@]}"; do lane[$name]=false; done

if [[ -z "$base" && -z "${HC_CHANGED_FILES:-}" ]]; then
  for name in "${lanes[@]}"; do print "$name=true"; done
  exit 0
fi

if [[ -n "${HC_CHANGED_FILES:-}" ]]; then
  changed=("${(@f)HC_CHANGED_FILES}")
else
  changed=("${(@f)$(git diff --name-only "$base...HEAD")}")
fi

for file in "${changed[@]}"; do
  [[ -z "$file" ]] && continue
  case "$file" in
    # Prose cannot change a build; the fast lane still checks links and maps.
    *.md|docs/*|LICENSE|NOTICE|.github/ISSUE_TEMPLATE/*|.claude/*)
      continue ;;
    # CI itself must prove every lane it defines.
    .github/workflows/*|.github/actions/*|scripts/classify_changes.sh)
      for name in "${lanes[@]}"; do lane[$name]=true; done
      continue ;;
  esac
  lane[macos]=true
  case "$file" in
    apps/ios/*|scripts/*ios*|scripts/*asr*|schemas/*|Tests/cuj/*|.swift-format|tools/swift_format/*|scripts/swift_format.sh)
      lane[ios]=true ;;
    # Shared by both apps.
    Sources/HardwareControllerCore/*|Sources/hardware_controller_voice_ffi/*|Sources/voice_*|crates/*|Cargo.*|rust-toolchain.toml|scripts/build_rust_ffi.sh)
      lane[ios]=true ;;
  esac
done

for name in "${lanes[@]}"; do print "$name=${lane[$name]}"; done
