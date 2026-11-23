---
title: Verify runs as parallel lanes inside the macOS job cap
priority: P1
rank: x
executor: agent
depends_on: [ci_warm_builds]
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

The required `Verify` check aggregates lanes that run at once: an Ubuntu lane
(`scripts/check_fast.sh`, Rust fmt, clippy, and tests, which are portable), a
macOS Swift lane (format lint, debug build, tests, opt-in suites), and a macOS
package lane (release build, symbol check, release-script tests, ad-hoc
smoke). `scripts/check.sh` runs the same lane scripts in sequence, so local
and CI coverage cannot drift.

| Criterion                         | One warm macOS job | Ubuntu + 2 macOS lanes | Package and smoke after merge only |
| --------------------------------- | ------------------ | ---------------------- | ---------------------------------- |
| Verify wall clock                 | 🟠 ~5 min est.     | 🟢 ~3 min est.         | 🟢 ~3 min est.                     |
| macOS jobs on a full-lane PR      | 🟢 1 of 5.         | 🟡 2 of 5.             | 🟢 1 of 5.                         |
| Every merged tree packaged first  | 🟢 Yes.            | 🟢 Yes.                | 🔴 No.                             |
| Local and CI coverage match       | 🟢 One script.     | 🟢 Same lane scripts.  | 🟠 Two paths.                      |

Recommendation: Ubuntu + 2 macOS lanes.

## Acceptance

- `Verify` stays the required check's name and fails unless every lane
  passed or was skipped by `scripts/classify_changes.sh`.
- Each macOS lane's p95 is under 3.5 minutes over at least 10 PRs.
- A full-lane PR runs at most 5 macOS jobs at once.
- `docs/CONTRIBUTING.md`'s lane table matches; `scripts/check.sh` passes.
