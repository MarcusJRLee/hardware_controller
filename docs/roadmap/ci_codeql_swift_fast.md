---
title: Swift CodeQL on a PR traces only what it changed
priority: P1
rank: z
executor: agent
depends_on: [ci_warm_builds]
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

A PR's Swift CodeQL jobs build everything untraced first, then trace only the
SwiftPM or Xcode targets whose sources changed, finishing in under 3.5
minutes. Pushes to `main` and the weekly run still trace everything. Today the
traced build alone takes 20 minutes per platform.

| Criterion                      | Trace changed targets only           | Swift CodeQL after merge only | Advisory, not required, on PRs | Larger paid runner   |
| ------------------------------ | ------------------------------------ | ----------------------------- | ------------------------------ | -------------------- |
| Fits 3.5 minutes               | 🟡 Hypothesis; Core changes riskiest. | 🟢 Nothing on PRs.           | 🔴 Still 23 min of CI.         | 🔴 ~12 min est.      |
| Findings before merge          | 🟢 For changed targets.              | 🔴 None.                      | 🟠 Only if you wait.           | 🟢 All.              |
| Cross-target data flow         | 🟠 Unchanged bodies absent; `main` run covers. | 🟢 Full, after merge. | 🟢 Full.                   | 🟢 Full.             |
| Cost                           | 🟢 None.                             | 🟢 None.                      | 🟢 None.                       | 🔴 ~$0.16/min.       |

Recommendation: trace changed targets only.

## Acceptance

- `scripts/classify_changes.sh` maps changed files to Swift targets, with
  tests.
- CodeQL (macos) and CodeQL (ios) p95 are under 3.5 minutes on PRs, measured
  for at least a Core-only and an App-only change; `main` still analyzes
  everything.
- If a Core change cannot meet the budget, the measured times and this matrix
  go to Ser before another column is chosen.
- The decision record states the coverage trade-off.
