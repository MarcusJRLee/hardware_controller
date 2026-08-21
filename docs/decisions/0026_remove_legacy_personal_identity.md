# 0026: Remove the legacy personal identity

- **Status:** Accepted
- **Date:** 2026-08-20
- **Supersedes:**
  [`0024_longdevity_application_identity.md`](0024_longdevity_application_identity.md)

## Context

The private identity transition copied existing local data into the Longdevity
Application Support directory and retained the source directory as a rollback
copy. Keeping that compatibility path in the clean public root would disclose
the exact predecessor personal namespace after its one-time purpose was
complete.

## Decision matrix

| Criterion | Retain the literal | Remove after transition | Supply it privately at runtime |
| --- | ---: | ---: | ---: |
| Sanitized public snapshot | No | Yes | Yes |
| No runtime configuration | Yes | Yes | No |
| Automatic import for skipped private builds | Yes | No | Conditional |
| Deterministic public storage namespace | Yes | Yes | No |

## Decision

- Remove the predecessor identifier and copy path from source, tests, and
  current documentation before creating the clean public root.
- Resolve application storage only under
  `com.longdevity.hardwarecontroller` and reject a file at that required path.
- Keep decision 0024 as historical evidence of the completed private
  transition.
- Do not delete either Application Support directory from the user's Mac.

## Consequences

- The clean public snapshot contains only the Longdevity application identity.
- An installation that skipped the private transition does not automatically
  import predecessor data.
- Existing migrated data and the retained local rollback copy are unchanged.

## Evidence

- Identity tests cover the public namespace, absent-directory resolution, and
  invalid-path failure without embedding a predecessor identifier.
- The tracked privacy scan rejects the predecessor personal namespace.
