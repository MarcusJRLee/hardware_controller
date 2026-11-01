#!/bin/zsh

set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ci_durations.sh"
tab=$'\t'

# Runs the report on fixture rows (name, minutes, queue) and checks one line.
expect() {
  local outcome="$1" message="$2" rows="$3" line="$4" output code=0
  output="$(HC_CI_DURATIONS_TSV="$rows" "$script" 0 --check)" || code=$?
  if [[ "$outcome" == pass ]]; then
    (( code == 0 )) || { print -u2 "Expected success: $message"; exit 1; }
  else
    (( code != 0 )) || { print -u2 "Expected failure: $message"; exit 1; }
  fi
  [[ "$output" == *"$line"* ]] || { print -u2 "Missing '$line' for $message:"$'\n'"$output"; exit 1; }
}

expect pass "jobs within budget" \
  "Verify${tab}3${tab}1.0"$'\n'"Verify${tab}4${tab}3.0"$'\n'"Verify${tab}12${tab}2.0" \
  "Verify                   3     4.0    12.0       2.0      15"
expect pass "jobs reused from an earlier attempt have no queue time" \
  "Verify${tab}3${tab}1.0"$'\n'"Verify${tab}4${tab}" \
  "Verify                   2     3.0     4.0       1.0      15"
expect pass "only reused jobs" "Verify${tab}3${tab}" \
  "Verify                   1     3.0     3.0         -      15"
expect fail "a median past 70% of the budget" \
  "Verify${tab}11${tab}0"$'\n'"Verify${tab}12${tab}0"$'\n'"Verify${tab}13${tab}0" \
  "OVER 70%"
print "ci_durations tests passed."
