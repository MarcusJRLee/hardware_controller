#!/bin/zsh

# Reports recent CI job durations against each job's timeout budget so slow
# growth is visible before it blocks merging.
# Usage: scripts/ci_durations.sh [runs] [--check]
#   --check fails when a job's p50 exceeds 70% of its timeout-minutes.
#   HC_CI_DURATIONS_TSV replaces the GitHub query (name, minutes, queue) for tests.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runs="${1:-30}"
check="${2:-}"

# Budgets come from the workflows themselves, so they cannot drift.
budgets="$(
  for workflow in "$repo_root"/.github/workflows/*.yml; do
    awk '
      /^  [a-z_]+:$/ { name = ""; timeout = "" }
      /^    name: / { sub(/^    name: /, ""); name = $0 }
      /^    timeout-minutes: / { timeout = $2 }
      name != "" && timeout != "" { print name "\t" timeout; name = ""; timeout = "" }
    ' "$workflow"
  done
)"

durations="${HC_CI_DURATIONS_TSV-}"
[[ -n "$durations" ]] || durations="$(
  gh run list --limit "$runs" --json databaseId,conclusion \
    --jq '.[] | select(.conclusion == "success") | .databaseId' \
    | while read -r run; do
      gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" \
        --jq '.jobs[] | select(.conclusion == "success")
          | (.started_at | fromdate) as $started | (.created_at | fromdate) as $created
          # A job reused from an earlier attempt keeps its old start time but
          # gets a new creation time, so its queue time is unknown.
          | [.name, (((.completed_at | fromdate) - $started) / 60),
             (if $started >= $created then ($started - $created) / 60 else "" end)] | @tsv'
    done
)"

# Multiline values go through the environment; awk -v rejects newlines.
print -r -- "$durations" | sort | HC_BUDGETS="$budgets" awk -F '\t' -v check="$check" '
  BEGIN {
    n = split(ENVIRON["HC_BUDGETS"], lines, "\n")
    for (i = 1; i <= n; i++) { split(lines[i], pair, "\t"); budget[pair[1]] = pair[2] }
  }
  $1 != "" { name = $1; minutes[name, ++count[name]] = $2; if ($3 != "") { queue[name] += $3; queued[name]++ } }
  END {
    printf "%-20s %5s %7s %7s %9s %7s\n", "job", "runs", "p50", "max", "queue avg", "budget"
    over = 0
    for (name in count) {
      n = count[name]
      for (i = 1; i <= n; i++) v[i] = minutes[name, i]
      for (i = 2; i <= n; i++) for (j = i; j > 1 && v[j - 1] > v[j]; j--) { t = v[j]; v[j] = v[j - 1]; v[j - 1] = t }
      p50 = v[int((n + 1) / 2)]
      limit = (name in budget) ? budget[name] : 0
      flag = (limit > 0 && p50 > 0.7 * limit) ? "  OVER 70%" : ""
      if (flag != "") over = 1
      wait = (queued[name] > 0) ? sprintf("%.1f", queue[name] / queued[name]) : "-"
      printf "%-20s %5d %7.1f %7.1f %9s %7s%s\n", name, n, p50, v[n], wait, limit, flag
    }
    if (check == "--check" && over) exit 1
  }'
