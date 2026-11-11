# Portable Voice engine

- **Status:** Accepted
- **Updated:** 2026-11-10 (portability check and platform seams)
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
- No Apple framework, type, target gate, link kind, path, or binding crate
  enters `crates/` or `Cargo.lock`, and the header includes only `<stddef.h>`
  and `<stdint.h>`; `scripts/check_conventions.sh` enforces it. Archive V1's
  `audio.caf` is a fixed file name whose bytes Rust only hashes, not an Apple
  API.
- Streaming ASR, formatting inference, cancellation, and runtime handles need
  their own versioned ownership design; they are not forced through this
  synchronous shape. Reconsider UniFFI if the interface becomes object-heavy or
  async and its Swift 6 support meets these gates.

## Platform seams

Each platform links the same static library and header and supplies the rest.
None is built; Apple is today's implementation.

| Seam | Apple (built) | Android | Windows | Linux |
| --- | --- | --- | --- | --- |
| Binding | Swift adapter; SwiftPM or XCFramework | Kotlin over JNI; per-ABI NDK archive | C/C++ or C# P/Invoke; MSVC archive | C/C++; the C17 smoke test already links it |
| Audio capture | `AVAudioEngine`; CAF | `AudioRecord` or AAudio | WASAPI | PipeWire or ALSA |
| File access | Sandbox URL → UTF-8 path | Copy SAF content into app-private storage, then pass its path | UTF-8 path; non-UTF-8 returns `INVALID_UTF8_PATH` | Same as Windows |
| Model storage | Application Support or app container; Swift fetcher | `noBackupFilesDir`; Kotlin fetcher | `%LOCALAPPDATA%`; native fetcher | `$XDG_DATA_HOME`; native fetcher |
| Text delivery | Accessibility and `CGEvent`; iOS keyboard | `InputMethodService` | UI Automation or `SendInput` | AT-SPI, IBus, or Wayland input method |

Every fetcher stages a package and passes it to Rust validation before use. A
platform that cannot write CAF needs a versioned archive V2, not a
platform-specific branch in Rust.

## Consequences

- The apps contain Rust but ship no extra process, dynamic library, or network
  entitlement. A checkout needs the pinned Rust toolchain; scripts own the build
  order.
- Rust layout tests and a C17 consumer compile, link, and run in every check.
- Shared CUJ fixtures (`Tests/cuj/`) test the linked boundary.
