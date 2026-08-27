# 0035: Portable Voice C ABI

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:**
  [`0029_local_voice_platform_expansion.md`](0029_local_voice_platform_expansion.md)

## Context

The Voice engine must reuse domain policy across Swift, Kotlin, and later native
desktop adapters without adding a local service or language runtime to the hot
path. The first extraction is the deterministic retention planner because it is
platform-neutral, safety-sensitive, and already has a stable Swift baseline.

The boundary must work with Swift 6 strict concurrency today and preserve an
Android path. [UniFFI 0.32](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md)
provides production Swift and Kotlin bindings, but its
[Swift 6 support](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html#swift-6-support)
remains partial and generated async interfaces are not yet `Sendable`. The
retention tracer is synchronous and value-oriented.

## Decision matrix

| Criterion | Narrow C ABI | UniFFI 0.32 |
| --- | --- | --- |
| Swift 6 strict concurrency | Synchronous call; a thin wrapper can be an immutable `Sendable` value. | Generated Swift support is partial; async surfaces require additional isolation work. |
| Kotlin path | Stable NDK/JNI wrapper over the same header. | Generated Kotlin bindings are mature. |
| Ownership audit | Caller owns every input and output buffer; no pointer survives return. | Generated runtime owns object and buffer conversion. |
| First tracer shape | Direct match for flat retention values and ordered decisions. | Object scaffolding adds machinery without improving this contract. |
| Tooling and reproducibility | Rust, a source-controlled header, and the platform C compiler. | Adds binding generation and generated-source drift controls. |
| Future async model APIs | Requires a separately designed handle or bounded callback contract. | Can generate higher-level async APIs once Swift 6 support is sufficient. |
| Unsafe surface | One reviewed `voice_ffi` crate; the domain crate denies unsafe code. | Generated FFI plus its runtime boundary. |

Select the narrow C ABI for the first portable engine boundary. Reevaluate
UniFFI when the shared interface becomes object-heavy or asynchronous and its
Swift 6 `Sendable` behavior meets the same gates.

## Contract

- `voice_core` owns portable policy and has no production dependencies. It
  denies unsafe Rust and imports no Apple type.
- `voice_ffi` is the only unsafe boundary. Exported names and layouts carry a
  `V1` suffix.
- Calls are synchronous. No allocator, callback, thread, runtime handle, or
  retained pointer crosses the ABI.
- The caller supplies decision memory. A zero-capacity call returns the required
  count; insufficient memory returns `VOICE_STATUS_BUFFER_TOO_SMALL` without a
  partial decision list.
- UUIDs use 16 network-order bytes. Times use signed Unix epoch milliseconds.
  Optional and Boolean fields accept only zero or one. Reserved bytes must be
  zero.
- Stable status codes preserve each domain validation failure; malformed ABI
  flags use a separate invalid-argument status.
- Rust layout tests and a C17 consumer compile, link, and execute in every
  repository check.
- Swift and Rust evaluate the same versioned CUJ fixture until the shipped app
  adopts the Rust implementation. Migration cannot silently change decisions.

## Consequences

The first Rust slice proves shared source, deterministic policy, C linkage, and
Swift parity without changing the installed macOS runtime. The Swift planner
remains the production implementation during convergence. Later Swift and
Kotlin wrappers must translate typed values and errors without adding policy.

Async ASR and formatting engines are not forced through this synchronous shape.
Their ownership, cancellation, and streaming contracts require separate measured
decisions before integration.

## Evidence

- `Tests/cuj/voice_retention_v1.json`
- `crates/voice_core/src/retention_test.rs`
- `Tests/HardwareControllerCoreTests/voice_history_retention_test.swift`
- `crates/voice_ffi/src/ffi_test.rs`
- `Tests/voice_ffi/retention_smoke.c`
