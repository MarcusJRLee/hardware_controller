---
title: CI reports how long a PR waits for feedback
priority: P1
rank: o
executor: agent
depends_on: []
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

`scripts/ci_durations.sh` reports PR feedback time, from a PR head's first CI
run's creation to its last CI or CodeQL job's completion, with p50, p95, max,
and sample count per lane set (fast, macOS, full). It also reports per-step
p50 for macOS jobs, so each later `ci_*` item proves its gain.

## Acceptance

- `scripts/ci_durations.sh 50` prints feedback-time and per-step rows;
  `scripts/ci_durations_test.sh` covers both from fixture TSV.
- The hand-measured 2026-11-23 baseline in
  `docs/decisions/builds_and_workflow.md` is replaced by this script's output.
- `scripts/check_fast.sh` passes.
