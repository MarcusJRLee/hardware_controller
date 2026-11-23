---
title: Every PR gets full CI feedback in under 5 minutes
priority: P1
rank: zi
executor: agent
depends_on: [ci_parallel_verify, ci_ios_fast, ci_codeql_swift_fast]
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

The 5-minute target is enforced: the weekly CI health run fails when PR
feedback p95 passes 5 minutes, and macOS job timeouts drop to 6 minutes so a
hang fails fast. `scripts/check_workflows.sh` caps, `docs/CONTRIBUTING.md`'s
lane table, and the decision record describe the new budgets.

## Acceptance

- `scripts/ci_durations.sh 50 --check` passes with PR feedback p95 under 5
  minutes over at least 20 macOS-lane PRs.
- The decision record's "Until the `ci_*` roadmap items land" sentence is gone.
- `scripts/check_fast.sh` passes.
