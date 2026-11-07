#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check_conventions.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Builds a passing tree: one tested source, one exempt source, a clean domain.
make_fixture() {
  rm -rf "$fixture" && mkdir -p "$fixture"
  cd "$fixture"
  mkdir -p Sources/HardwareControllerCore Sources/HardwareControllerMac Tests/Suite
  print 'import Foundation' > Sources/HardwareControllerCore/tested.swift
  print '' > Tests/Suite/tested_test.swift
  print 'struct V {}' > Sources/HardwareControllerCore/values.swift
  print 'Sources/HardwareControllerCore/values.swift | Values; used by `tested_test`.' \
    > Tests/untested_sources.txt
  print 'let s = URLSession.shared' > Sources/HardwareControllerMac/ollama_local_ai_refiner.swift
  print 'Sources/HardwareControllerMac/ollama_local_ai_refiner.swift | Adapter.' \
    >> Tests/untested_sources.txt
  git init -q && git add -A
}

# Applies one mutation to a fresh fixture and checks the outcome.
expect() {
  local outcome="$1" message="$2" mutation="$3"
  make_fixture
  eval "$mutation"
  git add -A
  if HC_CONVENTIONS_ROOT="$fixture" "$script" >/dev/null 2>&1; then
    [[ "$outcome" == pass ]] || { print -u2 "Expected failure: $message"; exit 1; }
  else
    [[ "$outcome" == fail ]] || { print -u2 "Expected success: $message"; exit 1; }
  fi
}

expect pass "a conforming tree" ':'
expect fail "a dashed path" 'print > Tests/bad-name.txt'
expect pass "a lefthook hook directory" 'mkdir -p .lefthook/pre-push && print > .lefthook/pre-push/rules.sh'
expect fail "a dashed lefthook script" 'mkdir -p .lefthook/pre-push && print > .lefthook/pre-push/my-rules.sh'
expect fail "an untested source" 'print > Sources/HardwareControllerCore/new_logic.swift'
expect fail "a stale exemption" 'print > Tests/Suite/values_test.swift'
expect fail "an exemption for a deleted file" 'rm Sources/HardwareControllerCore/values.swift'
expect fail "an exemption citing a missing test" 'perl -pi -e "s/tested_test/ghost_test/" Tests/untested_sources.txt'
expect fail "a framework import in the domain" 'print "import AppKit" >> Sources/HardwareControllerCore/tested.swift'
expect fail "a network API outside the Ollama adapter" 'print "URLSession.shared" >> Sources/HardwareControllerCore/tested.swift'
expect fail "web content outside the Gemini panel" 'print "import WebKit" >> Sources/HardwareControllerMac/ollama_local_ai_refiner.swift'
expect fail "the Xcode-bundled formatter in a script" 'mkdir scripts && print "swift format lint x" > scripts/lint.sh'
expect pass "the pinned formatter in a script" 'mkdir scripts && print "scripts/swift_format.sh lint x" > scripts/lint.sh'
print "check_conventions tests passed."
