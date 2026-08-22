# 0027: Individual public-source ownership

- **Status:** Accepted
- **Date:** 2026-08-21
- **Amends:**
  [`0025_public_source_publication.md`](0025_public_source_publication.md)
- **Licensing and contribution policy superseded by:**
  [`0028_apache_open_source_and_contributions.md`](0028_apache_open_source_and_contributions.md)

## Context

Decision 0025 expected Longdevity LLC to own the source before publication.
The entity will instead be formed later. The current copyright owner must be
the licensor until an existing entity receives the rights through a signed
written assignment.

## Decision matrix

| Criterion | Wait for Longdevity LLC | Publish under the individual owner |
| --- | ---: | ---: |
| Immediate accurate licensor | No | Yes |
| Public-source migration can proceed | No | Yes |
| Future company ownership | Direct | Signed assignment required |
| Current rights remain consolidated | Yes | Yes |

## Decision

- Name Marcus John Rice Lee as the current copyright owner and PolyForm
  Noncommercial licensor in `NOTICE`, app metadata, and current documentation.
- Keep external code contributions paused so future assignment and relicensing
  remain straightforward.
- Treat Longdevity LLC formation as future work rather than a public-repository
  gate.
- After Longdevity LLC exists, execute a signed written copyright assignment
  before changing the notice, licensing authority, or app metadata through a
  separate decision and pull request.
- Keep the `com.longdevity.hardwarecontroller` application identifier and
  Longdevity product namespace; branding does not assert present company
  ownership.

## Consequences

- The source can be published under an existing individual licensor.
- Commercial-license inquiries remain with Marcus John Rice Lee until a valid
  assignment changes ownership.
- Forming Longdevity LLC alone does not change copyright ownership or existing
  notices.

## Evidence

- `NOTICE`, app metadata, README, contribution policy, and publication gate
  name Marcus John Rice Lee.
- The migration runbook records Longdevity LLC formation and assignment as a
  later transition.
