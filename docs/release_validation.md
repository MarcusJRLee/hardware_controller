# Release validation — 1.4.0

**Acceptance date:** July 31, 2026.

This is the only retained accepted-artifact report. Current source changes are
unreleased and do not authorize a DMG, tag, GitHub Release, installation, or
replacement of this record. Git history retains obsolete intermediate reports.

## Commands

```sh
swift format lint --recursive --strict \
  Package.swift Sources Tests
xcrun clang-format --dry-run --Werror \
  Sources/HardwareControllerAudioBoundary/audio_engine_exception_boundary.m \
  Sources/HardwareControllerAudioBoundary/include/audio_engine_exception_boundary.h
swift test
zsh -n scripts/*.sh
scripts/build_release_test.sh

HC_RUN_MICROPHONE_INTEGRATION=1 swift test \
  --filter capturesARealAuthorizedMicrophoneBuffer

HC_RUN_MICROPHONE_ROUTE_INTEGRATION=1 swift test \
  --filter changesTheRealDefaultInputWithoutCrashing

set -a
source .env.local
set +a
scripts/build_release.sh
```

The release command requires clean `main` matching `origin/main`. It runs the
format, test, script, property-list, release-build, signature, entitlement,
architecture, deployment-target, DMG, and mounted-app checks before emitting
the artifact and version-specific evidence under `dist/`.

## Environment

| Field | Value |
| --- | --- |
| Mac architecture | Apple silicon, arm64 |
| macOS | 26.5.2 (25F84) |
| Xcode | 26.6 |
| Swift | 6.3.3 |
| Deployment target | macOS 15 or later |
| Runtime dependencies | Apple frameworks only |

## Automated evidence

`swift test` passes 223 tests across 37 suites. Opt-in tests that require a
real microphone, focused external field, installed app, or physical Device
skip during an ordinary run.

Version 1.4.0 adds deterministic coverage for:

- schema-1 and schema-2 migration into versioned multi-Profile storage;
- atomic Profile creation, duplication, rename, deletion, edit, and activation;
- per-Device setup resolution and conservative missing-setup behavior;
- active-Action cleanup and release-before-repress across Profile switches;
- Controller, Profiles, General, Command–Comma, and window-title navigation;
- persisted sidebar visibility and System, Light, and Dark appearance;
- transactional runtime, presentation, login-item, and preference failures.

The signed release run's 10,000-transition soak produced 10,000 ordered
dispatches with no pressed or active Control remaining:

| Metric | Result | Target |
| --- | ---: | ---: |
| p50 input-to-dispatch | 0.010 ms | ≤ 3 ms |
| p95 input-to-dispatch | 0.017 ms | ≤ 8 ms |
| p99 input-to-dispatch | 0.035 ms | ≤ 15 ms |
| Maximum | 0.174 ms | ≤ 30 ms |
| Extra or missing invocations | 0 | 0 |

The authorized built-in microphone passed five start/capture/stop cycles.
One-time non-capturing preparation took 84.808 ms. Warm activation measured
p50 126.831 ms, p95 128.281 ms, p99 128.281 ms, and maximum 128.281 ms across
five samples. The 250 ms maximum passed, and the engine remained stopped
between sessions.

The real built-in input passed prepared 48→44.1 kHz activation, active
44.1→48 kHz invalidation, cleanup, and recovery. The opt-in test restored the
original Device, rate, and channel configuration.

The macOS 26 local speech backend completed ten consecutive generated-audio
recognition and finalization cycles through the production implementation.

## Packaged UI and Device evidence

The exact signed app was exercised in deterministic demo mode and normal
release mode:

| Check | Result |
| --- | --- |
| Navigation | Controller, Profiles, and General route in one native window. |
| Native titles | Every destination updates the native title after repeated routing. |
| Sidebar | Native collapse and restore passed with the expanded state restored. |
| Settings command | Command–Comma routed Profiles to General. |
| Appearance | Light and Dark applied immediately; Dark was restored. |
| Profile setups | Coding and Music exposed distinct complete VEC Infinity 3 Bindings. |
| Profile activation | Activating Music updated both active-Profile pickers and Controller Bindings. |
| Accessibility | The tree exposed destinations, Profiles, Device setups, Controls, actions, appearance, and startup state. |
| Real Device | The signed normal-mode app matched the connected VEC USB Footpedal and reported Ready. |

The exact switch-while-held invariant is deterministic: the runtime ends every
active Action, clears pressed ownership, installs the replacement resolver,
and requires release plus a new press. The connected physical pedal was not
manually actuated during this final packaging pass; its raw mapping and all
simultaneous combinations remain fixture-backed by the accepted 1.3.5 capture.

## Artifact

| Field | Value |
| --- | --- |
| Version / build | 1.4.0 / 15 |
| Source commit | Retained in the private repository archive. |
| Signing | Apple Development; Team ID retained in private evidence. |
| Hardened runtime | Enabled |
| Entitlements | Audio input only |
| Architecture | arm64 |
| Minimum macOS | 15.0 |
| DMG bytes | 1,532,414 |
| DMG SHA-256 | `bfc3e6e0f02c4975d06099e656358a2205d43e31af9f5e40b977fd6171986a68` |
| Executable SHA-256 | `9ddcb1b696b18d2493c8e56334d835152a1a95969dc335262baa215302fe0d89` |
| Distribution | Private, local use |

The artifact passed strict deep signature verification, exact entitlement
verification, release build, DMG verification, and mounted-app equality. The
generated record is `dist/Hardware Controller-1.4.0.release.md`.

## Deferred evidence

These rows do not block this private local release. They remain required before
claiming the corresponding environment or public distribution support.

| Check | Reason |
| --- | --- |
| Final manual switch while a physical Control is held | The safety path is deterministic and the Device matched; the final pedal actuation was not repeated. |
| macOS 15–25 runtime | The deployment target builds and the binary minimum is 15.0; this Mac has no older-macOS VM or installation. |
| VoiceOver spoken output | The Accessibility tree passed; spoken output was not reviewed. |
| Clean-account installation | The mounted app passed integrity checks; no separate clean user session was used. |
| Public distribution | Developer ID signing and notarization credentials are unavailable. |

Version 1.4.0 build 15 is accepted for the tested private local-use scope.
