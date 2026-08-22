# 0028: Apache open source and contributions

- **Status:** Accepted
- **Date:** 2026-08-22
- **Supersedes licensing and contribution policy in:**
  [`0025_public_source_publication.md`](0025_public_source_publication.md) and
  [`0027_individual_publication_ownership.md`](0027_individual_publication_ownership.md)

## Context

The clean public repository launched under PolyForm Noncommercial 1.0.0 while
the owner evaluated commercial control and external contribution terms. The
owner now prioritizes broad use, transparent development, and low-friction
contributions over restricting commercial reuse.

## Decision matrix

| License | OSI open source | Distributed changes must remain open | Explicit patent grant | Adoption friction |
| --- | ---: | ---: | ---: | ---: |
| PolyForm Noncommercial 1.0.0 | No | Commercial use prohibited | No | Highest |
| Mozilla Public License 2.0 | Yes | Covered files only | Yes | Moderate |
| Apache License 2.0 | Yes | No | Yes | Lowest |

## Decision

- License the repository under the unmodified Apache License 2.0 with Marcus
  John Rice Lee as the current copyright owner.
- Welcome issues and pull requests. Treat intentionally submitted
  contributions as Apache-licensed under Section 5; contributors retain their
  copyright. Do not require a contributor license agreement or assignment.
- Keep official repository administration, review, and release authority with
  the maintainer. Clarify source-identification guidance without claiming a
  registered mark.
- Put a clone-and-demo path before maintainer verification commands. Separate
  demo, development, and signed-hardware paths.
- Keep one source-controlled verification command and run it on protected
  GitHub pull requests and `main`.
- Keep source licensing separate from binary release approval. A free public
  DMG still requires an exact approved version, Developer ID signing,
  notarization, stapling, Gatekeeper validation, and clean-account evidence.
- Forming Longdevity LLC and assigning Marcus's copyright remain future work.
  Third-party contributions remain available to the future project under
  Apache 2.0 without requiring ownership transfer.

## Consequences

- Individuals and companies may use, modify, redistribute, and sell the
  software subject to Apache 2.0.
- Downstream modifications may remain proprietary. Attribution, license, and
  modified-file notice requirements still apply.
- The official project gains a conventional contribution path and automated
  verification without weakening privacy or release gates.
- Previously published PolyForm snapshots retain their historical terms; the
  repository state carrying this decision is Apache-licensed.

## Evidence

- `LICENSE` matches the official Apache License 2.0 plain text.
- `NOTICE`, app metadata, README, contribution policy, and current planning
  documents name Marcus John Rice Lee accurately.
- `scripts/check.sh` is the local and GitHub verification entry point.
- GitHub issue forms, pull-request guidance, and code ownership are tracked.
- Public distribution remains a separate documented and explicitly approved
  workflow.
