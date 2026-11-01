#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check_docs.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# Builds a minimal tracked tree with one doc, one test file, and one journey.
make_fixture() {
  rm -rf "$fixture" && mkdir -p "$fixture"
  mkdir -p "$fixture/docs" "$fixture/Tests/Suite" "$fixture/apps"
  print -r -- "$1" > "$fixture/docs/voice_cujs.md"
  print -r -- 'func testReal() {}' > "$fixture/Tests/Suite/real_test.swift"
  git -C "$fixture" init -q
  git -C "$fixture" add -A
}

expect() {
  local outcome="$1" message="$2" doc="$3"
  make_fixture "$doc"
  if HC_DOCS_ROOT="$fixture" "$script" >/dev/null 2>&1; then
    [[ "$outcome" == pass ]] || { print -u2 "Expected failure: $message"; exit 1; }
  else
    [[ "$outcome" == fail ]] || { print -u2 "Expected success: $message"; exit 1; }
  fi
}

valid='[self](voice_cujs.md#top)

| ID | Journey | Proof |
| --- | --- | --- |
| H1 | Real | `real_test`, `testReal`, `Tests/Suite`, `{real}_test` |'

expect pass "every link and proof resolves" "$valid"
expect fail "a broken relative link" "${valid}
[gone](missing.md)"
expect fail "a missing test file" "${valid/real_test\`, \`testReal/ghost_test\`, \`testReal}"
expect fail "a missing test function" "${valid/testReal/testGhost}"
expect fail "a missing path" "${valid/Tests\/Suite/Tests\/Gone}"
expect fail "a missing brace alternative" "${valid/\{real\}/{real,ghost}}"
print "check_docs tests passed."
