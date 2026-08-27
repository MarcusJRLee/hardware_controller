# 0039: Link the portable Voice runtime into Apple applications

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:** [0035](0035_portable_voice_c_abi.md)

## Context

M11–M14 proved portable Rust policy, schemas, and a real C consumer, but the
macOS executable still used only Swift implementations. iOS needs one typed
Apple boundary without a REST service, generated binding runtime, retained
pointers, or a separately signed dynamic library.

## Decision matrix

| Criterion | Static Rust library and typed Swift adapter | Bundled Rust dynamic library | Local REST process |
| --- | ---: | ---: | ---: |
| In-process latency and lifecycle | 5 | 4 | 1 |
| Signing and installation simplicity | 5 | 2 | 1 |
| Pointer ownership audit | 5 | 5 | 3 |
| macOS/iOS source reuse | 5 | 4 | 2 |
| Stale-artifact prevention | 4 | 3 | 3 |
| Later Android adapter seam | 5 | 5 | 3 |
| **Total** | **29** | **23** | **13** |

## Decision

Use `HardwareControllerVoiceFFI` as a Swift 6 `Sendable`, pointer-free adapter
over the versioned C ABI. `VoiceFFIBridge` imports the source-controlled header;
SwiftPM statically links `target/release/libvoice_ffi.a`. Application code sees
only URLs, bounded limits, typed metadata, digests, and typed failures.

Canonical run, check, signed-build, and release paths build the optimized Rust
library before Swift. The build writes an ignored Swift source containing the
library digest only when bytes change. That source makes the Rust artifact an
observable Swift build input and forces relinking after Rust changes. Repository
checks also require the archive-verifier symbol in the release executable.

V1 History import invokes Rust against the importer-owned private snapshot,
compares the returned identity, result count, and audio presence with the Swift
model, then performs complete Swift graph validation and transactional restore.
The final revision 4 compatibility path remains Swift-only because it predates
the portable V1 contract. Model-package admission is available through the same
adapter for iOS model management.

This synchronous boundary validates finite artifacts only. Streaming ASR,
formatting inference, cancellation, and runtime handles require a separate
versioned ownership decision.

## Consequences

- The app contains Rust code but ships no additional process, service, dynamic
  library, network entitlement, or non-system dynamic dependency.
- A source checkout needs the pinned Rust toolchain before running or packaging
  the Swift app; repository scripts own the correct build order.
- ABI constants remain sourced from the C header through the bridge, while
  Swift enums reject unknown runtime, stage, capability, Boolean, and status
  values.
- Rust and Swift keep distinct responsibilities: Rust admits bounded portable
  artifacts; Swift owns Apple file access, compatibility migration, SQLite,
  audio custody, and presentation.

## Evidence

- `Sources/hardware_controller_voice_ffi/portable_voice_validator.swift`
- `Sources/voice_ffi_bridge/include/voice_ffi_bridge.h`
- `Tests/hardware_controller_voice_ffi_tests/portable_voice_validator_test.swift`
- `Tests/HardwareControllerMacTests/voice_history_archive_importer_test.swift`
- `scripts/build_rust_ffi.sh`
- `scripts/check.sh`
