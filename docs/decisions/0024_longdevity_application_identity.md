# 0024: Longdevity application identity

- **Status:** Superseded
- **Date:** 2026-08-19
- **Superseded by:**
  [`0026_remove_legacy_personal_identity.md`](0026_remove_legacy_personal_identity.md)
- **Amends:**
  [`0023_stable_personal_build_metadata.md`](0023_stable_personal_build_metadata.md)

## Context

The private build used a personal reverse-domain bundle identifier and tracked
one personal Apple Team identifier in maintainer instructions and validation
records. Public-source preparation needs a stable product namespace without
publishing personal signing configuration. A bundle-identifier replacement can
also strand existing Profiles and preferences or cause macOS to request privacy
authorization again.

## Decision matrix

| Direction | Public product namespace | Existing local data | Personal signing metadata in Git |
| --- | ---: | ---: | ---: |
| Keep the personal identifier | No | Preserved | Retained |
| Rename without migration | Yes | Lost from the app | Removed |
| Rename with non-destructive migration | Yes | Preserved | Removed |

## Decision

- Use `com.longdevity.hardwarecontroller` for the app bundle, logging
  subsystems, process queues, test capture labels, and Application Support.
- On first access, copy the former Application Support directory through a
  staged atomic rename only when the current directory is absent.
- Keep the former directory unchanged as rollback data. Never merge it over an
  existing current directory.
- Surface migration or storage construction failure instead of silently
  writing defaults over either location.
- Keep `HC_CODE_SIGN_IDENTITY` and `HC_EXPECTED_TEAM_ID` in ignored
  `.env.local`; track only `.env.example` placeholders.
- Keep version 1.4.1 build 17 unchanged. This identity change is not release
  approval.

## Consequences

- macOS treats the installed app as a new signed application identity and may
  require Accessibility, Microphone, Speech Recognition, and Launch at Login
  approval again.
- Existing Profiles and preferences appear under the Longdevity namespace
  without deleting the former data.
- Public source contains no personal Apple Team identifier or signing identity.
- Public contributors supply their own signing values for local builds.

## Evidence

- Identity tests cover the current namespace, legacy copy, current-directory
  precedence, source preservation, and invalid-path failure.
- Packaging and signed-app verification require the Longdevity bundle
  identifier.
- Repository privacy scans reject the former identifier except in migration
  declarations and tests.
