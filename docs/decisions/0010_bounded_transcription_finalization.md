# 0010: Bounded transcription finalization

- **Status:** Accepted; implemented in version 1.3.3
- **Date:** 2026-07-29
- **Amends:**
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)
  and
  [`0009_foreground_web_text_delivery.md`](0009_foreground_web_text_delivery.md)

## Context

Physical acceptance completed several rapid Dictation sessions before one
release remained in `Finalizing` indefinitely. The target writer had not run,
so the failure preceded Accessibility and Unicode event delivery.

The macOS 26 analyzer finalizer can throw `CancellationError` when analysis
finishes early. The controller treated every such error as an intentional app
cancellation and returned without leaving `Finalizing`. It also had no deadline
if a backend finalizer stopped making progress.

## Decision matrix

| Criterion | Unbounded finalization | Handle cancellation only | Bounded fail-safe |
| --- | --- | --- | --- |
| Recovers from unexpected backend cancellation | No. | Yes. | Yes. |
| Recovers from an unresponsive backend | No. | No. | Yes. |
| Preserves committed recovery text | Uncertain. | Yes. | Yes. |
| Applies equally to every target | Yes. | Yes. | Yes. |
| Keeps incomplete buffered text out of the target | Yes. | Yes. | Yes. |

## Decision

- Start one finalization task and one independent five-second watchdog after
  release.
- Treat `CancellationError` as intentional only after the session has already
  left its active state. Otherwise fail explicitly.
- On timeout, fail the session, stop audio, cancel recognition, and retain
  committed text for explicit copy recovery. Do not deliver incomplete
  buffered text.
- Model the macOS 26 recognition session as accepting input, finalizing, or
  stopped. Cancellation may interrupt either accepting input or finalization
  through `cancelAndFinishNow()`.
- Keep this policy in the shared transcription boundary. It must not depend on
  the target application or delivery route.

## Consequences

- No current Dictation session can remain in `Finalizing` indefinitely.
- A slow or failed backend becomes an actionable failure within five seconds.
- Successful finalization cancels its watchdog before target delivery.
- Explicit cancellation and shutdown can interrupt in-progress finalization.
- Buffered targets receive text only after successful finalization.

## Evidence

On July 29, 2026:

- deterministic tests reproduced both swallowed cancellation and an
  unresponsive finalizer before the fix;
- tests verified timeout failure, backend cancellation, explicit cancellation,
  successful watchdog cleanup, and committed-text recovery;
- the real macOS 26 backend completed ten consecutive local
  transcription/finalization cycles through one shared factory;
- 132 automated tests across 24 suites and the production build passed.
