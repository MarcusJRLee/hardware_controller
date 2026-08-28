# Decision 0051: Mark the integrated Voice personal QA build

**Status:** Accepted

**Branch workflow superseded by:**
[decision 0052](0052_main_feature_branch_workflow.md)

## Context

The accepted Voice program is integrated into `dev`, including the macOS Voice
workflow and local-only iOS app, keyboard, History, and system capture surfaces.
The canonical macOS app needs distinct metadata so installed evidence cannot be
confused with the pre-integration 1.4.1 build 17 candidate.

## Decision

- Set only the macOS app marketing version to 1.5.0 and build number to 18.
- Treat 1.5.0 build 18 as an unreleased Apple Development-signed personal QA
  build. This approval does not authorize a tag, DMG, GitHub Release,
  notarization, or public distribution.
- Keep the iOS app's independent version metadata unchanged.
- Build, verify, install, and launch the exact merged `dev` source at the single
  canonical `/Applications/Hardware Controller.app` path.
- Continue incrementing either value only after another exact user approval.

## Verification

The repository baseline, signed candidate validation, strict installed-bundle
signature, exact Team match, version/build metadata, candidate-to-installed
binary equality, and exact-bundle launch must pass before calling the canonical
app current.

## Implications

Decision 0023 remains the historical authority for preserving 1.4.1 build 17.
This decision supersedes its current-metadata selection without changing the
accepted 1.4.0 release record or authorizing release promotion.
