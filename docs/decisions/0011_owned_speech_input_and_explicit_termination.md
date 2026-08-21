# 0011: Owned speech input and explicit recognition termination

- **Status:** Accepted; implemented in version 1.3.4
- **Date:** 2026-07-29
- **Amends:**
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)
  and
  [`0010_bounded_transcription_finalization.md`](0010_bounded_transcription_finalization.md)

## Context

`AVAudioEngine` supplies mutable `AVAudioPCMBuffer` objects. The previous
capture adapter placed those objects directly into a `Sendable` stream under an
unchecked ownership assertion. The callback could return while recognition
still held a buffer that the engine remained free to reuse.

The shared transcription controller also treated `CancellationError` as
intentional during preparation, audio consumption, and result consumption.
Unexpected cancellation could therefore leave an active session in Preparing
or Listening, or let finalization succeed without complete result delivery.

## Decision matrix

| Criterion | Share callback buffers | Copy mutable buffers | Immutable sample values |
| --- | --- | --- | --- |
| Compiler-checked cross-isolation safety | No. | No; requires an unchecked invariant. | Yes. |
| Preserves the callback's samples | Unproven. | Yes. | Yes. |
| Keeps mutable PCM actor-local | No. | No. | Yes. |
| Supports macOS 15 | Yes. | Yes. | Yes. |
| Adds work to the HID hot path | No. | No. | No. |

## Decision

- Copy each microphone callback's valid PCM planes into immutable `Data` before
  returning from the callback.
- Carry format, frame length, and immutable planes in a compiler-checked
  `Sendable` value.
- Reconstruct mutable `AVAudioPCMBuffer` objects only inside a recognition
  actor. Keep conversion serialized inside the Speech input module.
- Bound queued microphone audio at 32 buffers. Treat a dropped buffer as an
  explicit audio failure.
- Permit result and audio streams to end normally only after finalization or
  explicit cancellation owns their termination.
- Ignore `CancellationError` only when the consuming Task is canceled or the
  session has already left its active state.
- Treat cancellation, failure, or early normal termination while active as an
  explicit recognition or audio failure. Retain committed recovery text and
  never deliver incomplete buffered text.
- Apply this policy equally to both Apple recognition adapters and every text
  delivery route.

## Consequences

- Mutable engine buffers never cross concurrency isolation.
- Preparation, Listening, and Finalizing cannot remain active because a
  backend cancellation was mistaken for user intent.
- The audio callback performs bounded in-memory copying. Copy cost and overflow
  behavior remain measured release gates separate from HID dispatch latency.
- Both recognition adapters expose the same termination contract to the shared
  controller.

## Evidence

Version 1.3.4 adds deterministic tests for sample ownership, interleaved audio,
empty and overflowing capture, preparation cancellation, audio cancellation,
result cancellation, early stream completion, finalization interruption,
explicit cancellation, and retained recovery text.
