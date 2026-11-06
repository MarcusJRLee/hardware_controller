#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/classify_changes.sh"

# Requires the lanes printed for a change set to equal the expected line.
expect() {
  local files="$1" expected="$2" actual
  actual="$(HC_CHANGED_FILES="$files" "$script" x | tr '\n' ' ')"
  [[ "$actual" == "$expected " ]] || {
    print -u2 "For [$files]: expected [$expected], got [$actual]"
    exit 1
  }
}

none="macos=false ios=false codeql_macos=false codeql_ios=false"
all="macos=true ios=true codeql_macos=true codeql_ios=true"
expect "README.md
docs/architecture.md
.claude/skills/verify/SKILL.md" "$none"
expect ".mjrlee_repo_setup/hooks/guard_git.py
.codex/hooks.json
.lefthook/pre-push/mjrlee_push_rules.sh
lefthook.yml" "$none"
expect "Sources/HardwareControllerMac/action_executor.swift" "macos=true ios=false codeql_macos=true codeql_ios=false"
expect "Sources/HardwareControllerCore/profile.swift" "$all"
expect "apps/ios/voice_input/app/voice_input_app.swift" "macos=true ios=true codeql_macos=false codeql_ios=true"
expect "Tests/HardwareControllerMacTests/action_executor_tests.swift" "macos=true ios=false codeql_macos=false codeql_ios=false"
expect "scripts/check_ios.sh" "macos=true ios=true codeql_macos=false codeql_ios=false"
expect "scripts/build_ios_rust_ffi.sh" "macos=true ios=true codeql_macos=false codeql_ios=true"
expect "scripts/prepare_ios_build_inputs.sh" "macos=true ios=true codeql_macos=false codeql_ios=true"
expect "scripts/fetch_asr_test_assets.sh" "macos=true ios=true codeql_macos=false codeql_ios=true"
expect "scripts/fetch_asr_runtime.sh" "macos=true ios=true codeql_macos=true codeql_ios=true"
expect "Sources/hardware_controller_asr_service_kit/asr_service_core.swift" "macos=true ios=false codeql_macos=true codeql_ios=false"
expect "scripts/check.sh" "macos=true ios=false codeql_macos=false codeql_ios=false"
expect "tools/swift_format/Package.resolved" "macos=true ios=true codeql_macos=false codeql_ios=false"
expect ".github/workflows/ci.yml" "$all"
expect ".github/actions/swift_format/action.yml" "$all"
expect "docs/user_guide.md
crates/voice_core/src/lib.rs" "$all"
[[ "$("$script" | tr '\n' ' ')" == "$all " ]] || { print -u2 "No base must run every lane."; exit 1; }
print "classify_changes tests passed."
