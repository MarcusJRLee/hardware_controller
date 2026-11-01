# Decision 0059: Change-scoped CI lanes

**Status:** Accepted

## Context

Every push ran four macOS jobs (Verify 5 min, iOS 8–14 min, CodeQL macOS and
iOS about 21 min each; the CodeQL-traced Swift build alone is 16–19 min). The
account runs only a few macOS jobs at once, and `main` requires up-to-date
branches, so each merge re-ran everything for the next PR. Queue waits reached
17 minutes and a six-PR series took hours.

| Criterion | Change-scoped lanes | Drop strict up-to-date | CodeQL post-merge only | Status quo |
| --- | --- | --- | --- | --- |
| macOS minutes for a docs PR | 0 | 62 | 19 | 62 |
| macOS minutes for a macOS-only PR | ~26 | 62 | 19 | 62 |
| Every merged tree verified before merge | Yes | No | Yes | Yes |
| Security findings before merge | Yes, for changed platforms | Yes | No | Yes |
| Ruleset change needed | No | Yes | Yes | No |
| Decision | Selected | Not now | Rejected | Replaced |

## Decision

- An Ubuntu `changes` job runs `scripts/classify_changes.sh` and gates every
  macOS job. Workflow and classifier edits run every lane.
- `Verify` always reports: prose-only changes run `scripts/check_fast.sh` on
  Ubuntu; anything else runs `scripts/check.sh` on macOS.
- `iOS` runs only for iOS, shared Core, FFI, Rust, and ASR inputs.
- CodeQL analyzes each Swift platform only when its sources change. An always-on
  `actions` analysis keeps the required `CodeQL` check reporting; a skipped
  Swift category shows as not found (neutral) and passes, which is sound because
  those sources match `main`'s last analysis. Pushes to `main` and the weekly
  schedule analyze every category.
- CI no longer runs on push to `main`: strict up-to-date squash merges make that
  tree identical to the verified PR.
- `scripts/check_workflows.sh` fails a job without a timeout, a macOS job over
  35 minutes or not gated by `changes`, an Ubuntu job over 15 minutes, or a
  workflow that does not cancel superseded runs. `scripts/ci_durations.sh`
  reports p50, max, and queue time against each job's own timeout, and the
  weekly CI health workflow fails when a p50 passes 70% of that budget.

## Consequences

A misclassified path could skip a lane; the classifier has its own tests, and
the weekly full CodeQL run plus every-lane workflow edits bound the exposure.
Adding a source directory may need a classifier rule.
