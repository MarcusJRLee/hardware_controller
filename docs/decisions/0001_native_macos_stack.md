# 0001: Native macOS stack

- **Status:** Accepted; HID ownership updated by
  [0004](0004_exclusive_vec_ownership.md) and transcription permissions updated
  by [0005](0005_app_owned_transcription.md)
- **Date:** 2026-07-24

## Context

The app must provide very low input latency, native macOS behavior, polished
menu bar and settings UI, direct USB HID access, global action execution, and a
credible path to signed distribution. It does not need a Windows or web version
in the first release.

## Decision matrix

Scores are relative for this product: 1 is weakest and 5 is strongest.

| Criterion                                    | Swift + SwiftUI/AppKit | Tauri + web UI | Electron |
| -------------------------------------------- | ---------------------: | -------------: | -------: |
| Direct IOKit and permission integration      |                      5 |              3 |        2 |
| Predictable input hot path                   |                      5 |              4 |        2 |
| Native menu bar, settings, and accessibility |                      5 |              3 |        3 |
| Runtime size and idle resource use           |                      5 |              4 |        1 |
| First-release implementation simplicity      |                      4 |              3 |        3 |
| Cross-platform reuse                         |                      1 |              4 |        5 |
| Signed macOS distribution fit                |                      5 |              3 |        3 |
| **Total**                                    |                 **30** |         **24** |   **19** |

Cross-platform UI reuse is not valuable enough to justify a bridge in the
latency-critical path or additional runtime surface.

## Decision

Use Swift 6 with strict concurrency. Build UI with SwiftUI and use focused
AppKit bridges for menu bar, window, responder-chain, or accessibility behavior
that SwiftUI cannot express reliably. Use IOKit HID APIs directly. Prefer Apple
frameworks and no third-party runtime dependencies in the first release.

Target macOS 15 or later while validating the primary personal build on macOS 26. Build for Apple silicon first; preserve source compatibility with a future
Universal 2 distribution build.

## Consequences

- Hardware transport and the visual app share a language and toolchain.
- Domain logic can live in independent Swift modules with strict compile-time
  isolation.
- The product intentionally chooses excellent macOS integration over
  cross-platform UI reuse.
- macOS-version compatibility must be tested; current-machine success is not
  evidence for the minimum deployment target.
- Phase 1 must validate sandboxed USB HID access before the Xcode project
  structure is treated as stable.

## Validation

The physical-device spike was completed on July 26, 2026. It proved that the
native process can discover and explicitly open the Infinity 3. It also proved
that nonexclusive observation cannot suppress the pedal's macOS pointer-button
behavior. Decision 0004 therefore supersedes this record's nonexclusive-open
requirement with exact-device exclusive ownership.

The 1.1.0 personal artifact validates the native stack, hardened runtime,
audio-input entitlement, and Apple Development signing. It is a direct,
non-sandboxed build. Physical sandbox behavior and any USB entitlement remain
a separate App Store investigation.
