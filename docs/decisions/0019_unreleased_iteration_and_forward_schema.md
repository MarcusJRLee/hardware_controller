# 0019: Unreleased iteration and forward-schema safety

- **Status:** Accepted
- **Date:** 2026-08-05
- **Metadata policy amended by:**
  [`0023_stable_personal_build_metadata.md`](0023_stable_personal_build_metadata.md)
- **Amends:**
  [`0014_multi_profile_device_configuration.md`](0014_multi_profile_device_configuration.md)
  and [`0018_exact_keyboard_control_fallback.md`](0018_exact_keyboard_control_fallback.md)

## Context

The keyboard-fallback build advanced Profiles to schema 4 while retaining the
1.4.0 build identity. macOS later opened the older installed binary, which
misclassified the newer Profile file as damaged and loaded Default in memory.
The original file remained intact, but the identical version/build labels made
the binaries ambiguous.

The user wants to iterate on 1.4.1 in Applications without promoting it to an
official release.

## Decision

The first clause below records the policy used for the initial iterations.
Decision 0023 replaces its per-install build-number increment; the signing,
canonical-install, schema-safety, and release-approval clauses remain active.

- Use marketing version 1.4.1 and build 16 for the first installed iteration.
  Keep 1.4.1 while iterating and increment the build number for each installed
  replacement.
- Sign every Applications build with an explicit Apple Development identity.
  Ad-hoc signatures are limited to disposable repo-local builds.
- Keep one canonical `/Applications/Hardware Controller.app`. Quit the prior
  process, replace the bundle, verify its identity and contents, then launch the
  installed path.
- Treat a syntactically valid schema newer than the app supports as an update
  requirement. Do not create a `.corrupt` copy, mutate the file, or allow the
  older app to overwrite it.
- Version metadata does not promote a release. Running the release workflow,
  creating a DMG or release record, tagging, or creating a GitHub Release
  requires explicit user approval for that exact version.

## Consequences

- Installed iterations are distinguishable from the accepted 1.4.0 build.
- Apple Development identity remains stable across personal replacements and
  preserves the intended permission posture better than ad-hoc signing.
- Rolling back cannot silently relabel or overwrite newer Profile data.
- Version 1.4.1 can receive multiple review builds without implying release
  acceptance.

## Evidence

- Profile-store tests distinguish later schemas from corruption and prevent
  overwrite.
- Runtime tests verify the update-required recovery message.
- Installation verification checks version, build, Team identifier, hardened
  runtime, entitlements, architecture, and the running bundle path.
