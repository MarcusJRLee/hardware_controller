---
title: CI builds start warm and build each product once
priority: P1
rank: u
executor: agent
depends_on: [ci_feedback_time]
specs: [docs/decisions/builds_and_workflow.md]
---

## Outcome

PRs restore Rust and Swift build state that `tool_cache.yml` saves on `main`,
and `scripts/build_app.sh --ad-hoc` reuses `scripts/check.sh`'s release build
instead of rebuilding it (75 s today). A restored cache can never produce a
stale product.

Rust `target/` caching per triple is safe as is: Cargo rebuilds workspace
crates whose mtimes are newer, and checkout makes them all newer. Swift needs a
choice; measure the first column before falling back:

| Criterion                     | Compilation caching (content-addressed) | `.build` cache, mtimes reset to the cache's commit | No Swift cache |
| ----------------------------- | --------------------------------------- | -------------------------------------------------- | -------------- |
| One-file PR debug build       | 🟢 Changed jobs only (hypothesis).      | 🟢 Changed modules only (hypothesis).              | 🔴 100 s.      |
| Stale-output risk             | 🟢 Keyed by content.                    | 🟠 A script must touch every file changed since.   | 🟢 None.       |
| Toolchain support             | 🟠 Xcode 26 builds; SwiftPM unproven.   | 🟢 Any SwiftPM.                                    | 🟢 Any.        |
| Fits the 10 GB cache limit    | 🟡 Needs pruning.                       | 🟠 Several GB per configuration.                   | 🟢 Nothing.    |

Recommendation: compilation caching where the toolchain supports it, mtime
reset only where it does not.

## Acceptance

- The iOS lane's Rust build takes under 20 s and macOS Verify's p50 drops by
  at least 2 minutes, per `scripts/ci_durations.sh`.
- If the mtime path is used, a colocated test proves a file changed since the
  cache's commit is rebuilt.
- `tool_cache.yml` saves every cache on `main` and weekly; their total stays
  under 8 GB.
- `scripts/check.sh` and `scripts/check_ios.sh` pass.
