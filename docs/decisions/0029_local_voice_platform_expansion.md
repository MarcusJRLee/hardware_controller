# 0029: Local Voice platform expansion

- **Status:** Accepted; macOS M1–M11 implemented
- **Date:** 2026-08-25
- **Amends:**
  [`0001_native_macos_stack.md`](0001_native_macos_stack.md),
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md), and
  [`0020_local_ai_dictation.md`](0020_local_ai_dictation.md)

## Context

Hardware Controller already owns low-latency microphone capture, local Apple
speech recognition, local text refinement, safe target delivery, Hold/Toggle
interaction, and exact keyboard fallback. The next product program adds durable
audio/transcript History, direct-audio local ASR providers, richer voice editing,
global keyboard capture, and an iOS custom keyboard without creating a second
macOS product.

The shared engine must remain portable enough to support Android, Windows, and
Linux later. Web and mobile web do not justify implementation or roadmap capacity
now.

## Platform priority

| Platform | Priority | Required outcome |
| --- | --- | --- |
| macOS | Active roadmap | Add Voice capabilities to the existing Hardware Controller app. |
| iOS | Active roadmap | Ship a containing app and full custom keyboard with local capture, inference, insertion, and History. |
| Android | Line of sight | Preserve portable engine, archive, provider, and CUJ contracts; do not build the app in this program. |
| Windows/Linux | Line of sight | Keep the engine free of Apple assumptions; native applications are later programs. |
| Web/mobile web | Deferred | Do not implement, prototype, or let browser constraints shape current milestones. |

## Decision

### Product and repository

- Keep one macOS application and add Voice as a first-class Hardware Controller
  capability. Do not create a sibling macOS app, helper product, or independent
  release track.
- Keep one repository. Migrate incrementally toward `apps/macos/`, `apps/ios/`,
  portable Rust crates, narrow Apple support packages, versioned schemas, and
  shared CUJ fixtures only when a green vertical slice requires each boundary.
- Preserve the current native Swift/AppKit/SwiftUI macOS integration. Platform
  UI, permissions, lifecycle, audio sessions, Accessibility, App Intents, and
  keyboard extensions remain native adapters.

### iOS keyboard

- Ship a containing iOS app and a full custom keyboard with a mic control.
- The keyboard extension never captures audio. The containing app owns
  microphone permission, AVAudioSession, local models, inference, background
  capture state, and History. The keyboard controls a confirmed session and
  inserts its final result.
- Treat cold/suspended containing-app activation as a signed-device and current
  App Review evidence gate. Use only documented, reviewable APIs; expose an
  honest app-switch/manual-return or recovery flow where the platform requires
  it.
- Keep the keyboard useful for ordinary typing without Full Access.

### Models and portability

- Use separate ASR and optional text-formatting model stages with deterministic
  spoken edits, validation, rendering, and Raw fallback around them.
- Select providers and Model packages by one corpus measuring quality, latency,
  memory, energy, installed size, license, and lowest-device behavior.
- Allow explicit Model-package downloads from approved sources before capture.
  Downloads carry no Voice content and must verify identity, digest, license,
  size, and compatibility before installation.
- Own portable orchestration, schemas, retention, validation, and model facades
  in Rust. Prefer Rust-native engines when they meet measured gates; permit
  mature C/C++ inference kernels only behind a narrow Rust safety boundary.
- Keep inference in-process. Do not add a local REST daemon or Go hot-path
  runtime. Remote providers remain a separately approved future capability.

### History and retention

- Store transcript stages and search metadata in SQLite with at most one
  retained audio artifact per Voice session.
- Default successful audio retention to 90 days, 2 GiB, or 5,000 artifacts on
  macOS and 90 days, 1 GiB, or 2,000 artifacts on iOS, whichever limit is
  reached first.
- Make age, bytes, count, and `Unlimited` independently configurable. Evict the
  oldest unpinned audio to a low-water mark while retaining searchable transcript
  metadata. Retain recoverable partial artifacts for 24 hours by default.
- Exclude owned Voice content from app-managed cloud sync and OS backup where
  supported. Disclose that external/manual backup systems remain outside the
  app's secure-erasure guarantee.

### CUJ-first delivery

- Treat [`../voice_cujs.md`](../voice_cujs.md) as the acceptance authority and
  M1 as the first tracer.
- Work in vertical red → green → refactor slices through public behavior. Do not
  write every test before implementation or couple tests to internal structure.
- Maintain a small stable E2E spine for critical journeys. Cover combinatorial
  edges below E2E through contract and adapter integration tests.
- Allow intentional CUJ changes when the same focused PR updates the acceptance
  document, behavior test, implementation, and rationale.

### Integration workflow

- Use `dev` as the program integration branch. Every logical slice uses a new
  `codex/voice_*` branch and a separate Git worktree, then a focused pull request
  targeting `dev`.
- Merge a pull request into `dev` only after its required checks pass. Continue
  autonomously through later slices. If repository policy prevents automated
  merge, keep work stacked and continue without bypassing protections.
- Do not merge `dev` into `main`, change release metadata, tag, publish a GitHub
  Release, submit to an app store, or promote a release until the user completes
  final verification and explicitly approves that action.
- Finish the program with polished macOS and iOS development builds, current
  documentation, and short installation, permission, model, and use instructions.

## Consequences

- Local Dictation remains in-memory-only and Apple-speech-only. The M1 slice
  replaces the in-memory-only policy for Local AI Dictation with one local CAF
  and distinct final text stages; later slices still own retention, recovery,
  portable ASR, and History presentation.
- macOS and iOS receive implementation capacity first. Portability is enforced
  through boundaries and conformance tests, not speculative Android, Windows,
  Linux, or browser applications.
- External evidence gaps never stop unrelated in-scope work. The final handoff
  may distinguish completed source from a platform-owner action such as App
  Review or physical-device confirmation, but it must exhaust all automatable
  evidence first.

## Acceptance authority

- [`../voice_platform_design.md`](../voice_platform_design.md)
- [`../voice_cujs.md`](../voice_cujs.md)
- [`../voice_implementation_goal_prompt.md`](../voice_implementation_goal_prompt.md)

## Implementation progress

The first macOS tracer composes the existing capture, Apple ASR, formatting,
validation, and delivery path. A bounded nonblocking tee writes audio on a
utility task; successful finalization synchronizes and atomically renames the
CAF before an actor-owned system SQLite transaction stores the Voice session.
Deterministic tests cover one insertion, every final text stage, playable audio,
database reopen, typed storage unavailability, and cancellation cleanup. Timed
Raw spans, UI, retention, crash reconciliation, portable Rust, alternate ASR,
and iOS remain subsequent CUJ slices.

M2 adds one disabled-by-default, machine-wide exact Voice chord to the existing
app. Its first key-down begins the coordinated Local AI workflow immediately;
release after a hold finishes, while two short presses latch and the next two
finish once. One Carbon owner reserves both active-Profile Binding fallbacks
and this distinct chord. Replacement and lifecycle interruption cancel Voice
ownership before registration teardown. Application preference schema 4 stores
the validated settings and migrates earlier schemas with the chord disabled.

M3 advances application preferences to schema 5 and stores one versioned
Natural, Casual Message, Formal, Technical, or Verbatim Style. Prompt revision
5 carries Style as typed untrusted payload data and centralizes its bounded
instructions. Verbatim bypasses the model. The Swift baseline converts
validated output into evidence-backed paragraph/list blocks, renders structure
only where the captured target supports it, and stores the encoded document in
a nullable SQLite column. Earlier schema-4 preferences default to Natural and
earlier Voice databases retain their rows with no structured document.

M4 adds a deterministic Swift spoken-edit engine before formatting. Exact
backtrack, sentence-delete, paragraph, numbered-list, and literal-escape phrases
become typed operations with source and affected-output UTF-8 evidence. One
strict replayer validates the revision and canonical trace before SQLite stores
or returns it from a nullable column. Raw is the trace source, so a Dictionary
replacement cannot synthesize a command; exact replacements run afterward to
produce Edited text. Provider failure delivers Edited text, while an empty
Edited result skips generation and insertion without discarding the session.
Ambiguous, near-match, and structurally inapplicable commands remain literal.
This amends the earlier Raw-only fallback wording: Raw remains recoverable, but
the one automatic fallback delivery uses deterministic Edited text whenever
that stage exists.

The M5 ownership guard requires Local AI to capture an empty caret without
discarding the target's native, web, or terminal delivery route. Before every
mutation it distinguishes target-process replacement, secure-state change,
focused-element replacement, and caret movement. Any invalidation withholds
automatic insertion, retains the final text and audio, and stores a stable
typed reason beside the human-readable failure. Existing History databases add
the nullable reason column without rewriting prior sessions. Copy recovery is
available immediately. M6 adds explicit History re-delivery as a new result
rather than mutating the failed one.

M6 adds History as the fourth destination in the existing macOS window. Each
session owns at most one CAF and an append-only graph of immutable results.
Search spans every stage; provenance and timed spans remain inspectable; and
correction, retranscription, reformatting, and explicit delayed re-delivery
append linked results. Export writes an open versioned package, pinning protects
future audio retention, and transactional deletion removes the session and its
owned audio. M7 subsequently delivered automatic quota enforcement under
[decision 0031](0031_bounded_voice_history_audio.md). M8 partial, orphan,
quarantine, row-corruption, and database-corruption recovery is implemented by
[decision 0032](0032_voice_history_crash_recovery.md).

M9 makes provider locality mandatory under
[decision 0033](0033_local_only_voice_enforcement.md). The router rejects a
remote-capable adapter before invoking it, validates provider identity, and
preserves deterministic Edited fallback. Recognition failure after capture
finalizes playable audio with delivery not attempted and never mutates the
target.

M10 converges physical Controls, Hold/latch Voice chords, and the menu-bar
record action on one process-owned Local AI command dispatcher under
[decision 0034](0034_voice_trigger_convergence.md). Trigger adapters retain only
their interaction semantics; session lifecycle, ASR, formatting, History,
retention, target validation, and delivery stay shared.

M11 begins portable-engine convergence under
[decision 0035](0035_portable_voice_c_abi.md). A dependency-free Rust planner
and the Swift production baseline evaluate one versioned retention CUJ fixture.
A synchronous `V1` C ABI uses caller-owned buffers, contains unsafe code in one
audited crate, and passes Rust layout plus real C compile/link/execute checks.
The shipped macOS app remains on the Swift planner until a later vertical slice
adopts the Rust implementation.
