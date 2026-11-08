# Builds, versions, and workflow

- **Status:** Accepted
- **Updated:** 2026-11-06 (added serial landing and toolchain drift policy)
- **Replaces:** 0019, 0023, 0051, 0052, 0059

## Context

Every change should reach the installed app so it can be checked against the
real Device and target apps, without version churn or accidental releases. An
older binary once misread a newer Profile schema as damaged. CI runs on few
macOS runners with strict up-to-date merges, so running every job on every PR
made queues of hours.

| Criterion                         | Change-scoped lanes | Drop strict up-to-date | CodeQL after merge only |
| --------------------------------- | ------------------- | ---------------------- | ----------------------- |
| macOS minutes for a docs PR       | 🟢 0.               | 🔴 62.                 | 🟠 19. |
| Every merged tree verified first  | 🟢 Yes.             | 🔴 No.                 | 🟢 Yes. |
| Security findings before merge    | 🟢 For changed platforms. | 🟢 Yes.          | 🔴 No. |

CI's Xcode is older than the maintainer's, and on 2026-11-01 three changes
passed locally and failed only in CI.

| Criterion                  | One local Xcode, documented patterns | Second local Xcode matching CI |
| -------------------------- | ------------------------------------ | ------------------------------ |
| Drift caught before push   | 🟠 Known patterns only.              | 🟢 All.                        |
| Local disk and upkeep      | 🟢 None added.                       | 🔴 A second install to update.  |

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
- PRs land one at a time, because each merge restarts the next PR's lanes
  ([Landing](../CONTRIBUTING.md#landing)). Agents may squash-merge PRs they
  opened once required checks pass.

**Toolchain**

- CI uses the `macos-26` image's default Xcode; maintainers keep one, newer,
  local Xcode rather than installing CI's. SDK and compiler drift therefore
  surfaces one CI run late, so known patterns live in
  [Toolchain compatibility](../CONTRIBUTING.md#toolchain-compatibility).
- `scripts/swift_format.sh` runs the formatter pinned in `tools/swift_format/`
  locally and on CI, so lint never drifts.

**Repo kit**

- The shared `mjrlee-repo-setup` kit manages `.mjrlee_repo_setup/`, the rules
  block in `AGENTS.md`, agent hooks (`.claude/settings.json`,
  `.codex/hooks.json`), and lefthook git hooks (`.lefthook/`,
  `lefthook.yml`'s `extends`). Update it by re-running the skill, never by hand.
- Its git hooks refuse pushes to or deleting `main` and any force push to it,
  warn when `main` changed the files a branch changes, and keep worktrees in
  `.worktrees/<name>`. They need the kit's tools: `mise trust && mise install`
  and `lefthook install` once per clone.
- `scripts/check_fast.sh` runs the kit's Markdown placement, Docker label, and
  roadmap gates, so CI installs the kit's tools through mise
  (`.github/actions/mise`), at the versions the kit pins. Kit-only changes take
  the fast lane.
- Markdown lives under `docs/`, in `README.md` files, skill trees, or
  `.github/`; `CONTRIBUTING.md` and `SECURITY.md` live in `docs/`, where GitHub
  also reads them.

**CI**

- An Ubuntu `changes` job runs `scripts/classify_changes.sh` and gates every
  macOS job; workflow and classifier edits run every lane.
- `Verify` always reports: prose-only changes run `scripts/check_fast.sh` on
  Ubuntu, anything else `scripts/check.sh` on macOS. `iOS` runs for iOS, shared
  Core, FFI, Rust, and ASR inputs.
- CodeQL analyzes a Swift platform only when its sources change; an always-on
  `actions` analysis keeps the required check reporting. Pushes to `main` and a
  weekly schedule analyze everything. CI does not re-run on push to `main`,
  because a strict up-to-date squash merge equals the verified PR.
- `scripts/check_workflows.sh` fails a job without a timeout, a macOS job over
  35 minutes or not gated by `changes`, an Ubuntu job over 15 minutes, or a
  workflow that does not cancel superseded runs. A weekly health workflow fails
  when a job's p50 passes 70% of its timeout (`scripts/ci_durations.sh`).

## Consequences

- Several personal iterations share one version and build number.
- Changed 2026-11: adopted the repo kit; root `CONTRIBUTING.md`,
  `SECURITY.md`, and `BRANDING.md` moved into `docs/`.
- A misclassified path could skip a lane; the classifier has tests, and the
  weekly full CodeQL run bounds the exposure. A new source directory may need a
  classifier rule.
