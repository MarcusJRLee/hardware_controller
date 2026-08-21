# 0023: Stable personal-build metadata

- **Status:** Accepted
- **Date:** 2026-08-19
- **Identity policy amended by:**
  [`0024_longdevity_application_identity.md`](0024_longdevity_application_identity.md)
- **Amends:**
  [`0019_unreleased_iteration_and_forward_schema.md`](0019_unreleased_iteration_and_forward_schema.md)

## Context

Every repository change should reach the canonical Applications bundle so the
user can verify the exact current source against the physical Device and target
apps. Automatically changing version metadata on each replacement adds churn
without representing release acceptance or a product milestone.

Forward-schema protection already prevents an older app from overwriting valid
newer configuration. A Git commit, code-signing identity, and installed binary
digest distinguish personal iterations when bundle metadata remains stable.

## Decision

- After every repository change, build the current source with the approved
  Apple Development identity, quit and replace the canonical Applications
  bundle, verify it, then launch that exact installed bundle.
- Preserve `CFBundleShortVersionString` and `CFBundleVersion` during routine
  changes. An agent may recommend a change but must receive explicit user
  approval for the exact new value before applying it.
- Keep release promotion separate. A tag, DMG, GitHub Release, release record,
  or release-script run still requires explicit approval for the exact version.
- Retain the forward-schema and canonical-install protections from decision
  0019.

## Consequences

- Multiple personal iterations can share one marketing version and build
  number.
- Verification and handoff identify an installed iteration by source commit,
  signing Team, and binary digest rather than bundle metadata alone.
- Version and build changes become deliberate product decisions instead of
  side effects of installation.
- Every completed repository change leaves the canonical Applications bundle
  ready for immediate physical verification.

## Evidence

- Installation checks compare the source commit's built candidate with the
  canonical installed binary.
- Signature checks require the private Apple Development Team configured by
  `HC_EXPECTED_TEAM_ID`.
- Profile and preference stores preserve later schemas without mutation.
