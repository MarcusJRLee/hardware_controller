---
title: The iOS lane finishes in under 3.5 minutes
priority: P1
rank: y
executor: agent
depends_on: [ci_warm_builds]
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

The iOS lane, one macOS job, finishes in under 3.5 minutes at p95 and still
proves every UI journey with the recorded clip. Today it takes 17.9 minutes:
Rust 3.5 (fixed by `ci_warm_builds`), `build-for-testing` 3, unit tests about
1.5, and five UI tests about 6.5. Profile each UI test from the result bundle
before choosing what to cut.

| Criterion                     | One job, faster UI journeys      | Separate UI-test job             | UI tests after merge only |
| ----------------------------- | -------------------------------- | -------------------------------- | ------------------------- |
| Fits 3.5 minutes              | 🟡 If UI time drops ~4x (hypothesis). | 🟢 Runs in parallel.        | 🟢 Yes.                   |
| macOS jobs on a full-lane PR  | 🟢 Keeps 5 of 5.                 | 🔴 6 of 5: the PR queues.        | 🟢 5 of 5.                |
| Journeys proven before merge  | 🟢 Yes.                          | 🟢 Yes.                          | 🔴 No.                    |

Recommendation: one job with faster UI journeys, such as one launch for
several journeys, a shorter clip, or a smaller test Model.

## Acceptance

- `scripts/check_ios.sh` prints each test's duration from the result bundle.
- The iOS job's p95 is under 3.5 minutes over at least 10 PRs.
- Every UI journey in `docs/voice_cujs.md` that CI proves today still runs
  on every iOS-lane PR.
- `scripts/check_ios.sh` passes.
