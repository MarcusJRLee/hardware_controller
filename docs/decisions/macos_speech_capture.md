# macOS speech capture and sessions

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0005, 0010, 0011, 0012, 0015, 0017, 0022

## Context

The app owns Dictation so it can report authoritative state and keep audio
local. Real use found sessions stuck in Finalizing, mutable audio buffers
crossing isolation, AVFAudio aborting on stale formats after a route change,
false route failures after pinning a microphone, and format errors from pinning
System Default. The speech engine itself is chosen in
[asr_runtime](asr_runtime.md).

| Criterion                         | Reuse prepared format | Negotiated format only | Route lease plus containment |
| --------------------------------- | --------------------- | ---------------------- | ---------------------------- |
| Prevents the observed rate abort  | 🔴 No.                | 🟢 Yes.                | 🟢 Yes. |
| Detects Device, rate, channel change | 🔴 No.             | 🔴 No.                 | 🟢 Yes. |
| Contains AVFAudio exceptions      | 🔴 No.                | 🔴 No.                 | 🟢 At one Objective-C boundary. |
| Keeps warm activation             | 🟢 Yes.               | 🟢 Yes.                | 🟢 While the route is unchanged. |

| Criterion                         | Always pin the Device | Never pin | Pin explicit choice only |
| --------------------------------- | --------------------- | --------- | ------------------------ |
| System Default rate negotiation   | 🔴 Fails to start.    | 🟢 Works. | 🟢 Works. |
| App-local microphone              | 🟢 Yes.               | 🔴 No.    | 🟢 Yes. |

## Decision

**Session**

- At most one microphone-owning session in the process. Hold begins on press
  and finalizes on release; Toggle begins and finalizes on successive presses.
  Disconnect, Profile change, permission loss, sleep, and shutdown cancel or
  finalize through the same serialized owner.
- Apple recognition, when selected or as a fallback: `SpeechAnalyzer` with
  `DictationTranscriber` on macOS 26+, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition` on 15–25. Refuse a locale without on-device
  support; never fall back to a server request.
- Request Microphone permission everywhere, and Speech Recognition only for the
  legacy recognizer. Accessibility stays required for targeting and delivery.
- Resolve speech assets and the first microphone format at authorized idle
  startup; never start the engine or capture before a press.

**Finalization and termination**

- After release, run finalization with an independent five-second watchdog. On
  timeout, fail, stop audio, cancel recognition, keep committed text for copy
  recovery, and deliver no incomplete buffered text.
- Ignore `CancellationError` only when the consuming task was canceled or the
  session already left its active state. Cancellation, failure, or early stream
  end while active is an explicit failure.
- Model the macOS 26 session as accepting input, finalizing, or stopped;
  `cancelAndFinishNow()` can interrupt either active phase.

**Audio ownership**

- Copy each callback's valid PCM planes into immutable `Data` before the
  callback returns, carried in a `Sendable` value. Rebuild mutable buffers only
  inside the recognition actor.
- Bound queued audio at 32 buffers; a dropped buffer is an audio failure.

**Routes and microphone choice**

- An input route is Device identity, nominal rate, channel count, and an
  observation generation. Every prepared engine is leased to one route; re-read
  it before and after preparation and activation and rebuild on any change.
- Use AVFAudio's negotiated tap format, never a cached one. Discard an engine
  after any start failure or incomplete cleanup.
- Wrap only AVFAudio tap, prepare, start, and stop in Objective-C
  `@try/@catch` and convert exceptions to `NSError`.
- A route change fails an active capture exactly once. An engine-configuration
  notification with an unchanged route gets one serialized prepare/start
  recovery on the engine's queue; a second one fails the session.
- Never mutate or release an engine on AVFAudio's notification callback. Retire
  invalid engines and keep them alive for the capture boundary's lifetime;
  `stop()` releases hardware.
- General lists System Default plus every input Device. Persist the Device UID
  and last name, never a CoreAudio object ID, and exclude
  `CADefaultDeviceAggregate-` UIDs.
- Set `kAudioOutputUnitProperty_CurrentDevice` only for an explicit, present
  Device; never change the system default. A missing saved Device stays saved,
  shows as unavailable, and capture uses System Default until it returns.
  Changing the choice cancels active Dictation first.

## Consequences

- No session can stay in Preparing, Listening, or Finalizing indefinitely.
- A framework assertion becomes a recoverable audio failure, and a route change
  ends the current session; the next press rebuilds.
- Evidence: a real 44.1→48 kHz built-in switch completed activation,
  invalidation, cleanup, and recovery in 0.972 s; an explicit Device delivered
  24 buffers without changing the system default (steady interval p50
  96.084 ms, p95 106.745 ms, max 106.771 ms).
- Audio-copy cost and overflow stay measured separately from HID dispatch
  latency.
