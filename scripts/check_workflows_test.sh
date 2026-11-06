#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/check_workflows.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

valid='name: CI
concurrency:
  group: ci
  cancel-in-progress: true
jobs:
  changes:
    runs-on: ubuntu-latest
    timeout-minutes: 5
  build:
    needs: changes
    runs-on: macos-26
    timeout-minutes: 20'

# Writes one workflow and checks the outcome.
expect() {
  local outcome="$1" message="$2" workflow="$3"
  print -r -- "$workflow" > "$fixture/ci.yml"
  if HC_WORKFLOW_DIR="$fixture" "$script" >/dev/null 2>&1; then
    [[ "$outcome" == pass ]] || { print -u2 "Expected failure: $message"; exit 1; }
  else
    [[ "$outcome" == fail ]] || { print -u2 "Expected success: $message"; exit 1; }
  fi
}

expect pass "budgeted, gated jobs" "$valid"
expect fail "a job without a timeout" "${valid/    timeout-minutes: 20/}"
expect fail "a macOS job over budget" "${valid/timeout-minutes: 20/timeout-minutes: 60}"
expect fail "an ungated macOS job" "${valid/    needs: changes/}"
path_gated='name: Cache
on:
  push:
    paths:
      - tools/**
concurrency:
  group: cache
  cancel-in-progress: true
jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 20'
expect pass "a macOS job gated by push paths" "$path_gated"
expect pass "a macOS job gated by push paths-ignore" "${path_gated/paths:/paths-ignore:}"
expect fail "an ungated macOS job without push paths" "${path_gated/    paths:
      - tools\/\*\*
/}"
expect fail "an Ubuntu job over budget" "${valid/timeout-minutes: 5/timeout-minutes: 30}"
expect fail "no superseded-run cancellation" "${valid/cancel-in-progress: true/cancel-in-progress: false}"
print "check_workflows tests passed."
