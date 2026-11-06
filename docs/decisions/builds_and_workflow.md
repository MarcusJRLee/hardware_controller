# Builds, versions, and workflow

- **Status:** Accepted
- **Updated:** 2026-11-06
- **Replaces:** 0019, 0023, 0051, 0052, 0059

## Context

Every change should reach the installed app so it can be checked against the
real Device and target apps, without version churn or accidental releases. An
older binary once misread a newer Profile schema as damaged. CI runs on few
macOS runners with strict up-to-date merges, so running every job on every PR
made queues of hours.

| Criterion                         | Change-scoped lanes | Drop strict up-to-date |
| --------------------------------- | ------------------- | ---------------------- |
| macOS minutes for a docs PR       | 🟢 0.               | 🔴 62.                 |
| Every merged tree verified first  | 🟢 Yes.             | 🔴 No.                 |

A required CodeQL check made every Swift PR wait ~21 minutes, of which ~19 is
the traced Swift build; `Verify` takes ~7. The 2026-11-06 change moved CodeQL
after merge.

| Criterion                        | CodeQL on PRs (was) | CodeQL after merge | Larger CodeQL runners |
| -------------------------------- | ------------------- | ------------------ | --------------------- |
| Wait before a Swift PR can merge | 🔴 ~21 min.         | 🟢 ~7 min.         | 🟠 ~12–15 min, unmeasured. |
| Security findings before merge   | 🟢 Yes.             | 🔴 No; on `main` within ~25 min. | 🟢 Yes. |
| Runner cost                      | 🟢 Standard.        | 🟢 Standard.       | 🔴 Paid minutes. |

## Decision

**Personal builds**

- After every repository change, `scripts/install_app.sh` builds with the
  approved Apple Development identity, quits and replaces the single
  `/Applications/Hardware Controller.app`, verifies it, and launches that
  bundle. Ad-hoc signatures are for disposable local builds only.
- Verification checks version, build, Team (`HC_EXPECTED_TEAM_ID`), hardened
  runtime, entitlements, architecture, candidate-to-installed binary equality,
  and the running path. An iteration is identified by commit, Team, and binary
  digest.
- `CFBundleShortVersionString` and `CFBundleVersion` change only with explicit
  approval of the exact value. The macOS app is 1.5.0 build 18, an unreleased
  personal QA build; the iOS app's version is independent.
- A tag, DMG, GitHub Release, release record, notarization, App Store
  submission, or `scripts/build_release.sh` run needs explicit approval of that
  exact version. A public DMG also needs Developer ID signing, notarization,
  stapling, Gatekeeper validation, and clean-account evidence.

**Configuration safety**

- A valid configuration newer than the app supports is an update requirement:
  no `.corrupt` copy, no mutation, no overwrite by the older app.

**Branches**

- `main` is the only long-lived branch. Each change uses a focused branch from
  the latest `main` and a pull request, merged only after required checks pass;
  never bypass protections.
- Keep behavior, tests, migrations, and docs together in one PR; split
  unrelated work. Merging is source control only, never release approval.

**CI**

- An Ubuntu `changes` job runs `scripts/classify_changes.sh` and gates every
  macOS job; workflow and classifier edits run every lane.
- `Verify` always reports: prose-only changes run `scripts/check_fast.sh` on
  Ubuntu, anything else `scripts/check.sh` on macOS. `iOS` runs for iOS, shared
  Core, FFI, Rust, and ASR inputs.
- CodeQL is not a PR check. Each push to `main` that changes more than prose,
  and a weekly schedule, analyze every category (actions, macOS Swift, iOS
  Swift). Fix a finding with a follow-up PR. CI does not re-run on push to
  `main`, because a strict up-to-date squash merge equals the verified PR.
- `scripts/check_workflows.sh` fails a job without a timeout, a macOS job over
  35 minutes or not gated by `changes` or push paths, an Ubuntu job over 15
  minutes, or a workflow that does not cancel superseded runs. A weekly health
  workflow fails when a job's p50 passes 70% of its timeout
  (`scripts/ci_durations.sh`).

## Consequences

- Several personal iterations share one version and build number.
- A misclassified path could skip a lane; the classifier has tests. A new
  source directory may need a classifier rule.
- A PR can merge with a new CodeQL finding; it surfaces on `main` minutes
  later. CodeQL's prose `paths-ignore` duplicates the classifier's prose
  patterns; drift costs at most one week, bounded by the scheduled run.
