# Contributor guide

## Choose a path

| Goal | Command or entry point | Device or signing required |
| --- | --- | --- |
| Explore the UI | `swift run HardwareController --demo` | No |
| Verify a change | `scripts/check.sh` | No |
| Verify portable Rust and C ABI | `scripts/check_rust.sh` | No |
| Exercise real hardware | Signed build from `scripts/build_app.sh` | Yes |
| Run an opt-in system check | [README verification commands](../README.md#opt-in-system-verification) | Named resource only |

Demo mode uses deterministic process data and does not request Accessibility,
Microphone, Speech Recognition, or hardware access. Tests replace process
boundaries and skip opt-in system checks unless their environment flag is set.
`scripts/check.sh` runs the required SQLite contention and HID latency checks in
separate test processes. The contention check deliberately holds a writer lock;
the HID check measures scheduler latency. Isolation keeps either from distorting
unrelated parallel suites.

## Source map

| Path | Responsibility |
| --- | --- |
| `Sources/HardwareControllerCore/` | Hardware-independent domain values, Binding state, Profiles, migrations, and transcript policy. |
| `Sources/HardwareControllerMac/` | IOKit, Accessibility, audio, speech, local refinement, persistence adapters, and process runtime. |
| `Sources/HardwareControllerAudioBoundary/` | Narrow Objective-C exception boundary around AVFAudio operations. |
| `Sources/HardwareControllerApp/` | AppKit application lifecycle, SwiftUI presentation, navigation, and presentation state. |
| `crates/voice_core/` | Dependency-free portable Voice domain policy; unsafe Rust is denied. |
| `crates/voice_ffi/` | Versioned synchronous C ABI and source-controlled public header. |
| `Tests/*Tests/` | Colocated target-level unit and boundary tests mirroring source ownership. |
| `Tests/*Tests/fixtures/` | Sanitized hardware and Local AI evidence used by deterministic tests. |
| `Tests/cuj/` | Versioned cross-language behavior fixtures. |
| `Tests/voice_ffi/` | Real C consumers for ABI compile, link, and execution checks. |
| `packaging/` | Bundle metadata, entitlements, and source artwork. |
| `scripts/` | Verification, private signing, release validation, and distribution tooling. |

Read [`CONTEXT.md`](../CONTEXT.md) for deep implementation names and
[`architecture.md`](architecture.md) for ownership, data flow, isolation, and
security boundaries.

## Test placement

Add `FILENAME_test.swift` beside the source target's tests for every file with
behavioral logic. Test pure state in `HardwareControllerCoreTests`, macOS
boundary behavior in `HardwareControllerMacTests`, presentation and process
composition in `HardwareControllerAppTests`, and the Objective-C seam in
`HardwareControllerAudioBoundaryTests`.

Tests must not prompt for permissions, require a connected Device, contact a
remote host, or consume a real microphone unless an explicit opt-in flag names
that dependency. Use immutable fixtures and injected clocks, stores, and
system boundaries for the default suite.

Portable policy changes update the shared CUJ fixture, Rust test, Swift
conformance test, public header when applicable, and decision record together.
Keep unsafe code inside `voice_ffi`; platform wrappers translate values and
errors without adding policy.

## Adding a Driver

1. Add a narrow Device signature and report decoder without changing domain
   or UI behavior for existing Drivers.
2. Emit normalized Control events using stable model and Control identities.
3. Supply generic capability and layout metadata.
4. Add sanitized report fixtures for press, release, repeat suppression,
   simultaneous Controls, reconnect, and disconnect while active.
5. Keep unsupported or changed firmware rejected until physical evidence
   proves compatibility.
6. Measure callback-to-dispatch p50, p95, p99, maximum, and sample count.

## Signed Device testing

Copy `.env.example` to ignored `.env.local`, replace both placeholders with
your own Apple Development identity and Team identifier, then follow the
[signed-build commands](../README.md#signed-hardware-build). Never commit that
file or install an ad-hoc-signed build in `/Applications`.
