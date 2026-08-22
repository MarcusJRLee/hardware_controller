# 0025: Public source publication

- **Status:** Accepted
- **Date:** 2026-08-20
- **Ownership amended by:**
  [`0027_individual_publication_ownership.md`](0027_individual_publication_ownership.md)
- **Licensing and contribution policy superseded by:**
  [`0028_apache_open_source_and_contributions.md`](0028_apache_open_source_and_contributions.md)
- **Supersedes:**
  [`0008_infinity_3_iconography.md`](0008_infinity_3_iconography.md)
- **Builds on:**
  [`0024_longdevity_application_identity.md`](0024_longdevity_application_identity.md)

## Context

Public publication needs an explicit source license, copyright designation,
generic product mark, history boundary, contribution policy, and repository
security baseline. The private history contains personal author metadata and
tracked signing identifiers that must not become part of the public repository.

## Decision matrices

| License | Noncommercial use | Commercial use | OSI open source | Future broader licensing |
| --- | ---: | ---: | ---: | ---: |
| All rights reserved | No grant | No grant | No | Available to the sole owner |
| PolyForm Noncommercial 1.0.0 | Yes | No | No | Available while rights remain consolidated |
| Apache 2.0 | Yes | Yes | Yes | Already broad |

| History strategy | One hosted repository after migration | Personal history excluded | Hosted metadata retained |
| --- | ---: | ---: | ---: |
| Rewrite existing Git history | Yes | Harder to prove | Yes |
| Keep a second private repository | No | Yes | Yes |
| Replace with one clean root commit | Yes | Yes | No |

## Decision

- Publish the source under the unmodified PolyForm Noncommercial License 1.0.0.
  This is source-available licensing, not OSI-approved open source.
- Use `Required Notice: Copyright © 2026 Longdevity LLC` and the same holder in
  app metadata. Confirm the entity exists and owns the rights before making the
  repository public.
- Pause external code contributions until separate contributor terms preserve
  Longdevity LLC's ability to offer later or commercial licenses.
- Use Signal Bridge as the provisional app icon: three generic control nodes
  joined by one signal path with an active amber center. Use a matching generic
  template mark in the menu bar. This replaces Device-specific iconography and
  uses no manufacturer assets.
- Prepare a sanitized repository locally, create an offline bundle of the
  private history, delete the old hosted repository, recreate
  `MarcusJRLee/hardware_controller` privately, and push one root commit authored
  with the GitHub noreply identity. Do not maintain two hosted repositories.
- Audit the replacement repository before changing visibility. Enable branch
  rules, secret scanning, push protection, dependency alerts, code scanning,
  and private vulnerability reporting before or immediately upon publication.
- Keep source publication separate from binary release approval.

## Consequences

- The public repository permits qualifying noncommercial use but not commercial
  use without a separate license.
- Future broader licensing remains practical while external rights stay
  consolidated.
- Issues and pull-request history from the private repository do not transfer to
  the clean replacement.
- The public Git history contains no private predecessor commits.
- Signal Bridge is intentionally provisional and may be superseded by a later
  original identity decision.

## Evidence

- `LICENSE` matches the official PolyForm Noncommercial 1.0.0 plain text.
- `NOTICE`, app metadata, README, and contribution policy name Longdevity LLC.
- The packaged icon is generated from the committed Signal Bridge raster.
- The migration runbook defines the private-history bundle, clean root, same-name
  replacement, security controls, and visibility checks.
- The publication gate records only operational migration and security work as
  remaining.
