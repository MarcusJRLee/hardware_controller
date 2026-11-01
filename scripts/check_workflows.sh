#!/bin/zsh

# Keeps CI from silently growing: every job has a time budget, macOS jobs (the
# scarce runners) are gated by the change classifier, and every workflow
# cancels superseded runs. Budgets are documented in CONTRIBUTING.md.

set -euo pipefail

workflow_dir="${HC_WORKFLOW_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.github/workflows}"
macos_budget=35
ubuntu_budget=15

failures=()
for workflow in "$workflow_dir"/*.yml; do
  name="${workflow:t}"
  grep -q '^  cancel-in-progress: true$' "$workflow" \
    || failures+=("$name: add concurrency with cancel-in-progress: true")

  # Jobs are two-space keys under `jobs:`; their settings are four-space keys.
  job="" timeout="" runner="" gated=0
  check_job() {
    [[ -z "$job" ]] && return
    if [[ -z "$timeout" ]]; then
      failures+=("$name/$job: set timeout-minutes")
    elif [[ "$runner" == *macos* ]]; then
      (( timeout <= macos_budget )) || failures+=("$name/$job: timeout $timeout exceeds the ${macos_budget}-minute macOS budget")
      (( gated )) || failures+=("$name/$job: gate macOS work on the changes job (needs: changes)")
    else
      (( timeout <= ubuntu_budget )) || failures+=("$name/$job: timeout $timeout exceeds the ${ubuntu_budget}-minute budget")
    fi
  }
  in_jobs=0
  while IFS= read -r line; do
    if [[ "$line" == "jobs:" ]]; then
      in_jobs=1
      continue
    fi
    (( in_jobs )) || continue
    if [[ "$line" =~ '^  ([a-z_]+):$' ]]; then
      check_job
      job="${match[1]}" timeout="" runner="" gated=0
    elif [[ "$line" =~ '^    timeout-minutes: ([0-9]+)$' ]]; then
      timeout="${match[1]}"
    elif [[ "$line" =~ '^    runs-on: (.*)$' ]]; then
      runner="${match[1]}"
    elif [[ "$line" == "    needs: changes" ]]; then
      gated=1
    fi
  done < "$workflow"
  check_job
done

if (( ${#failures} )); then
  print -u2 -l "${failures[@]}"
  exit 1
fi
print "Workflows stay within their CI budgets."
