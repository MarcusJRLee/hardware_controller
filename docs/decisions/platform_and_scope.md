# Platform and scope

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0001, 0029

## Context

The app needs very low input latency, direct USB HID access, native menu bar
and settings UI, global Actions, and signed distribution. Voice then grew into a
program: durable History, local ASR providers, voice editing, global capture,
and an iOS keyboard, without creating a second macOS product.

| Criterion                          | Swift + SwiftUI/AppKit | Tauri + web UI | Electron |
| ---------------------------------- | ---------------------- | -------------- | -------- |
| Direct IOKit and permissions       | 🟢 Native.             | 🟡 Bridged.    | 🟠 Bridged. |
| Predictable input hot path         | 🟢 No bridge.          | 🟡 One bridge. | 🟠 JS runtime. |
| Native menu bar and accessibility  | 🟢 Yes.                | 🟡 Partial.    | 🟡 Partial. |
| Idle footprint                     | 🟢 Small.              | 🟡 Moderate.   | 🔴 Large. |
| Cross-platform UI reuse            | 🔴 None.               | 🟢 High.       | 🟢 High. |

## Decision

**Stack**

- Swift 6 with strict concurrency, SwiftUI plus focused AppKit bridges, and
  IOKit HID directly. Apple frameworks only at runtime unless a decision here
  approves otherwise.
- Target macOS 15 or later, validated on macOS 26. Apple silicon first, source
  compatible with a later Universal 2 build.

**Products and platforms**

| Platform       | Priority      | Outcome |
| -------------- | ------------- | ------- |
| macOS          | Active        | Voice is a capability of Hardware Controller, not a sibling app. |
| iOS            | Active        | Voice Input: a containing app plus a full custom keyboard. |
| Android        | Line of sight | Keep the engine, archive, provider, and CUJ contracts portable; build nothing. |
| Windows, Linux | Line of sight | Keep the engine free of Apple assumptions. |
| Web            | Deferred      | Do not let browser constraints shape anything. |

- One repository: `apps/`, portable Rust crates, narrow Apple packages,
  versioned schemas, and shared CUJ fixtures, each added only when a working
  slice needs it.
- Platform UI, permissions, lifecycle, audio sessions, Accessibility, App
  Intents, and keyboard extensions stay native adapters.

**Voice pipeline**

- ASR and optional text formatting are separate stages, with deterministic
  spoken edits, validation, rendering, and fallback around them.
- Providers and Model packages are chosen by one corpus measuring quality,
  latency, memory, energy, size, license, and lowest-device behavior.
- Inference stays on-device: in-process, or on macOS in an app-embedded XPC
  service ([asr_runtime](asr_runtime.md)). No local REST daemon, network
  listener, or Go runtime. Remote providers need their own decision.
- Portable orchestration, schemas, retention, and validation live in Rust
  ([portable_voice_engine](portable_voice_engine.md)). Mature C/C++ kernels are
  allowed behind a narrow boundary.

**Acceptance**

- [`../voice_cujs.md`](../voice_cujs.md) is the acceptance authority. Work in
  vertical red → green → refactor slices through public behavior.
- Keep a small stable end-to-end spine; cover combinatorial edges with contract
  and adapter tests.
- A CUJ may change only in a PR that updates the journey, its test, the code,
  and the rationale together.
- Missing external evidence (App Review, a physical device) never blocks
  unrelated work, but handoff must exhaust automatable evidence first.

## Consequences

- Hardware and UI share one toolchain; domain logic lives in independent
  modules under strict isolation.
- The product trades cross-platform UI reuse for macOS integration.
- Minimum-OS behavior needs its own testing; current-machine success is not
  evidence for macOS 15.
- The 1.1.0 build validated the native stack, hardened runtime, audio
  entitlement, and Apple Development signing. It is non-sandboxed; App Store
  sandboxing and any USB entitlement remain an open investigation.
