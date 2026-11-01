#!/bin/zsh

# Decides which CI lanes a change needs so expensive macOS jobs run only when
# their inputs changed. Prints GitHub output lines (`lane=true|false`).
# Usage: classify_changes.sh [<base-sha>]
#   Without a base (push, schedule, manual), every lane runs.
#   HC_CHANGED_FILES (newline-separated) replaces the git diff, for tests.

set -euo pipefail

base="${1:-}"
lanes=(macos ios codeql_macos codeql_ios)
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
    .github/workflows/*|scripts/classify_changes.sh)
      for name in "${lanes[@]}"; do lane[$name]=true; done
      continue ;;
  esac
  lane[macos]=true
  case "$file" in
    # Only inputs to the traced iOS build need the iOS CodeQL lane.
    apps/ios/*|scripts/build_ios_rust_ffi.sh|scripts/fetch_asr_runtime.sh|scripts/generate_ios_project.sh)
      lane[ios]=true; lane[codeql_ios]=true ;;
    scripts/*ios*|scripts/*asr*)
      lane[ios]=true ;;
    Sources/HardwareControllerCore/*|Sources/hardware_controller_voice_ffi/*|Sources/voice_*|crates/*|Cargo.*|rust-toolchain.toml|scripts/build_rust_ffi.sh)
      # Shared by both apps.
      lane[ios]=true; lane[codeql_ios]=true; lane[codeql_macos]=true ;;
    Sources/*|Package.swift)
      lane[codeql_macos]=true ;;
    schemas/*|Tests/cuj/*|.swift-format)
      lane[ios]=true ;;
  esac
done

for name in "${lanes[@]}"; do print "$name=${lane[$name]}"; done
