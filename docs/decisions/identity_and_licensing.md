# Identity, licensing, and publication

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0024, 0025, 0026, 0027, 0028

## Context

Publishing the source needed a license, an accurate copyright holder, a
product namespace free of personal signing data, a clean history, and a
contribution path. The owner prioritizes broad use and easy contributions over
restricting commercial reuse.

| License                      | OSI open source | Patent grant | Adoption friction |
| ---------------------------- | --------------- | ------------ | ----------------- |
| PolyForm Noncommercial 1.0.0 | 🔴 No; no commercial use. | 🔴 No. | 🔴 Highest. |
| Mozilla Public License 2.0   | 🟢 Yes.         | 🟢 Yes.      | 🟡 File-level copyleft. |
| Apache License 2.0           | 🟢 Yes.         | 🟢 Yes.      | 🟢 Lowest. |

## Decision

- License the repository under the unmodified Apache License 2.0. Marcus John
  Rice Lee is the copyright owner and is named in `NOTICE`, app metadata, and
  docs.
- Welcome issues and pull requests. Submitted contributions are licensed under
  Apache 2.0 Section 5; contributors keep their copyright, with no CLA or
  assignment. Repository administration, review, and releases stay with the
  maintainer. No registered mark is claimed.
- The app identity is `com.longdevity.hardwarecontroller` for the bundle,
  logging subsystems, queues, and Application Support. Storage resolves only
  there and rejects a file at that path. The former personal identifier and its
  migration path are removed from source; no user data is deleted.
- Signing identity and Team identifiers live only in ignored `.env.local`;
  `.env.example` holds placeholders.
- The public repository is one clean root commit authored with the GitHub
  noreply identity; private history is kept offline, not hosted. Branch rules,
  secret scanning, push protection, dependency alerts, code scanning, and
  private vulnerability reporting are on.
- Forming Longdevity LLC and assigning copyright to it is future work and needs
  a signed assignment and a new decision before any notice changes.
- Source licensing never approves a binary release
  ([builds_and_workflow](builds_and_workflow.md)).

## Consequences

- Anyone may use, modify, redistribute, and sell the software under Apache 2.0;
  modifications may stay proprietary with attribution and notices.
- Earlier PolyForm snapshots keep their historical terms.
- A tracked privacy scan rejects the former personal namespace.
