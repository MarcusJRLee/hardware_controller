# Portable Voice engine

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0035, 0039, 0057

## Context

Voice policy must be shared by Swift today and Kotlin or native desktop
adapters later, without a local service or a binding runtime in the hot path.

| Criterion                  | Narrow C ABI | UniFFI 0.32 |
| -------------------------- | ------------ | ----------- |
| Swift 6 strict concurrency | 🟢 Synchronous calls wrap as `Sendable` values. | 🟠 Partial; async surfaces are not `Sendable`. |
| Kotlin path                | 🟢 NDK/JNI over the same header. | 🟢 Mature bindings. |
| Ownership audit            | 🟢 Caller owns every buffer. | 🟡 Generated runtime owns conversion. |
| Tooling drift              | 🟢 Rust, one header, the C compiler. | 🟠 Generated sources to keep current. |

| Criterion                  | Static library + typed Swift adapter | Bundled dynamic library | Local REST process |
| -------------------------- | ------------------------------------ | ----------------------- | ------------------ |
| In-process latency         | 🟢 Direct call. | 🟢 Direct call. | 🔴 Network hop. |
| Signing and installation   | 🟢 Nothing extra. | 🟠 Second signed binary. | 🔴 A service to run. |
| macOS/iOS reuse            | 🟢 Same source. | 🟡 Same source. | 🟠 Separate lifecycle. |

## Decision

- `voice_core` holds portable policy with no production dependencies and denies
  unsafe Rust. `voice_ffi` is the only unsafe crate.
- Exported names and layouts carry a version suffix (`V1`, `V2`). Calls are
  synchronous; no allocator, callback, thread, handle, or pointer crosses or
  survives the call. The caller supplies output memory; a zero-capacity call
  returns the required size, and too little memory returns
  `BUFFER_TOO_SMALL` with no partial output.
- UUIDs are 16 network-order bytes, times are signed Unix milliseconds,
  Booleans and optionals accept only 0 or 1, and reserved bytes must be zero.
  Stable status codes keep each validation failure distinct.
- Output layouts never change in place: V2 keeps the complete V1 prefix and
  appends (for example, Model-package languages). Old versions keep exporting
  and testing until removed by a decision.
- `HardwareControllerVoiceFFI` is a pointer-free Swift 6 adapter over the
  header. SwiftPM links `target/release/libvoice_ffi.a` statically; iOS links
  one ignored XCFramework built for device and simulator. App code sees only
  URLs, limits, typed metadata, digests, and typed errors.
- The build writes an ignored Swift file containing the library digest when its
  bytes change, so Rust changes always relink. Checks require the archive
  verifier symbol in the release executable.
- History retention has one implementation, the Rust planner, called by both
  apps through `RustVoiceHistoryRetentionPlanner`. Swift keeps the value types
  and settings validation; unknown statuses fail as `portablePolicyFailure`.
- Rust admits bounded portable artifacts. Swift owns Apple file access,
  compatibility migration, SQLite, audio custody, and presentation.
- Streaming ASR, formatting inference, cancellation, and runtime handles need
  their own versioned ownership design; they are not forced through this
  synchronous shape. Reconsider UniFFI if the interface becomes object-heavy or
  async and its Swift 6 support meets these gates.

## Consequences

- The apps contain Rust but ship no extra process, dynamic library, or network
  entitlement. A checkout needs the pinned Rust toolchain; scripts own the build
  order.
- Rust layout tests and a C17 consumer compile, link, and run in every check.
- Shared CUJ fixtures (`Tests/cuj/`) test the linked boundary.
