---
title: A notarized build is publicly downloadable
priority: P3
rank: g
executor: human
depends_on: [clean_account_evidence]
specs: [docs/public_distribution.md]
---

## Outcome

An approved version ships as a Developer ID signed, notarized, stapled
GitHub Release, as `docs/public_distribution.md` describes.

## Acceptance

- Human: set up the Developer ID identity and notary credential, and approve
  the exact version.
- `scripts/notarize_release.sh` reports Accepted and Gatekeeper passes.
