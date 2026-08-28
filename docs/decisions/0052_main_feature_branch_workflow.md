# Decision 0052: Integrate focused feature branches through main

**Status:** Accepted

**Date:** 2026-08-28

**Supersedes:** The `dev` integration-branch workflow in
[decision 0029](0029_local_voice_platform_expansion.md) and the execution
instructions derived from it. Release approval remains unchanged.

## Context

The accepted Voice program completed on `dev`. Keeping a permanent integration
branch after that program finished would duplicate the default branch, require
manual promotion, and let documentation or fixes drift between two long-lived
lines. The user directed future work to use individual feature branches from
`main` and to remove `dev` without losing its reviewed history.

| Criterion | Focused branches into `main` | Permanent `dev` integration branch |
| --- | ---: | ---: |
| One current integration line | 5 | 2 |
| Required-check visibility | 5 | 5 |
| Risk of branch drift | 5 | 2 |
| Focused review and rollback | 5 | 5 |
| Extra promotion ceremony | 5 | 1 |
| **Total** | **25** | **15** |

## Decision

- Preserve the completed `dev` history through pull request 39 into `main`,
  verify the merge, then delete the local and remote `dev` branches.
- Create each subsequent `codex/*` feature branch from the latest integrated
  `main` and target its focused pull request at `main`.
- Merge only after required checks pass. Keep dependent work stacked when a
  repository rule prevents an immediate merge; do not bypass protections.
- Keep behavior, tests, migrations, and documentation together when they form
  one vertical change. Split unrelated responsibilities into separate PRs.
- Treat integration into `main` as source control only. It does not approve a
  tag, release version, DMG, GitHub Release, notarization, App Store submission,
  or public binary.

## Consequences

- `main` is the only long-lived integration branch.
- Completed program history remains reachable through the preservation merge
  and its original pull requests.
- Current documentation no longer describes a pending `dev` promotion gate.
- Release metadata and distribution remain separately and explicitly gated.
