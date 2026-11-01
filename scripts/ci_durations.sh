#!/bin/zsh

# Reports recent CI job durations against their timeout budgets so slow growth
# is visible before it blocks merging. Usage: scripts/ci_durations.sh [runs]

set -euo pipefail

runs="${1:-30}"
gh run list --limit "$runs" --json databaseId,conclusion \
  --jq '.[] | select(.conclusion == "success") | .databaseId' \
  | while read -r run; do
    gh api "repos/{owner}/{repo}/actions/runs/$run/jobs" \
      --jq '.jobs[] | select(.conclusion == "success")
        | [.name, (((.completed_at | fromdate) - (.started_at | fromdate)) / 60),
           (((.started_at | fromdate) - (.created_at | fromdate)) / 60)] | @tsv'
  done \
  | sort \
  | awk -F '\t' '
    { name = $1; run[name, ++count[name]] = $2; queue[name] += $3 }
    END {
      printf "%-20s %5s %7s %7s %9s\n", "job", "runs", "p50 min", "max min", "queue avg"
      for (name in count) {
        n = count[name]
        for (i = 1; i <= n; i++) values[i] = run[name, i]
        asort_values(values, n)
        printf "%-20s %5d %7.1f %7.1f %9.1f\n", name, n, values[int((n + 1) / 2)], values[n], queue[name] / n
      }
    }
    function asort_values(a, n,   i, j, t) {
      for (i = 2; i <= n; i++) for (j = i; j > 1 && a[j - 1] > a[j]; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t }
    }'
