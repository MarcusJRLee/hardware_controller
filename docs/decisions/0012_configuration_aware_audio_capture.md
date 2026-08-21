# 0012: Configuration-aware audio capture

- **Status:** Accepted; implemented in version 1.3.5
- **Date:** 2026-07-30
- **Amends:**
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)
  and
  [`0011_owned_speech_input_and_explicit_termination.md`](0011_owned_speech_input_and_explicit_termination.md)

## Context

Version 1.3.4 prepared one `AVAudioEngine` during application warm-up and
reused its input-node output format for later tap installation. A real launch
prepared against a 44.1 kHz Bluetooth route. macOS then changed the default
input to the 48 kHz built-in microphone and posted an engine-configuration
notification. The prepared engine retained 44.1 kHz state.

AVFAudio rejected the stale explicit format with:

`format.sampleRate == inputHWFormat.sampleRate`

The framework raised an Objective-C exception rather than a Swift error, so the
process aborted. The same latent path existed before 1.3.4. Using a `nil` tap
format avoids that exact mismatch but does not define resource invalidation,
active-session behavior, failed-engine reuse, or exception containment.

## Decision matrix

| Criterion | Reuse prepared format | Negotiated format only | Configuration lease plus containment |
| --- | --- | --- | --- |
| Prevents the observed rate mismatch | No. | Yes. | Yes. |
| Detects Device/rate/channel changes | No. | No. | Yes. |
| Defines active-session behavior | No. | No. | Yes. |
| Prevents reuse after graph failure | No. | No. | Yes. |
| Contains AVFAudio graph exceptions | No. | No. | Yes, at a narrow Objective-C boundary. |
| Preserves warm activation | Yes. | Yes. | Yes, while the configuration is unchanged. |

## Decision

- Define an input route as default Device identity, nominal sample rate, and
  input channel count.
- Observe default-input changes plus the current Device's nominal rate and
  input-stream configuration.
- Assign every prepared engine to one route and observation generation.
- Re-read the live route before and after preparation and activation. Rebuild
  when identity, rate, channels, or generation differ.
- Use AVFAudio's negotiated tap format instead of passing a cached format.
- Discard an engine after any start failure or incomplete cleanup.
- Fail an active capture exactly once when its configuration changes. The
  transcription controller performs normal failure cleanup; the next begin
  rebuilds against the current input.
- Wrap only AVFAudio tap, prepare, start, and stop mutations in Objective-C
  `@try`/`@catch`. Convert framework exceptions into `NSError` values before
  returning to Swift. Do not catch domain or application exceptions.
- Keep all audio, route inspection, and recovery local. Add no runtime
  dependency or network capability.

## Consequences

- Warm resources remain reusable only while their complete input configuration
  is current.
- Route changes during idle or active use cannot reuse a stale tap format.
- A framework assertion becomes a recoverable audio failure instead of a
  process abort.
- A route change ends the current Dictation; the user starts a new session
  after macOS finishes switching.
- The Apple-only runtime gains one small Objective-C target because Swift
  cannot catch `NSException`.

## Evidence

- The exception-boundary regression reproduced the exact AVFAudio process abort
  before containment and passes after containment.
- Deterministic tests cover stale preparation, missed notifications, sample-rate
  and channel changes, redundant invalidations, observer failure, failed-engine
  discard, observer retry, recovery, and 1,000 consecutive route generations.
- The authorized microphone passes five start/capture/stop cycles with a
  104.414 ms worst warm activation.
- The real built-in input passes prepared 48→44.1 kHz activation, active
  44.1→48 kHz invalidation, cleanup, and recovery. The test restores the
  original system input configuration.

## Build 14 amendment — framework-safe engine retirement

Build 13 acceptance switched a prepared 16 kHz Bluetooth Device to the 48 kHz
built-in input. One run returned the typed configuration failure; the next
produced `EXC_BAD_ACCESS` while `AVAudioEngine` deinitialized concurrently with
its internal `AVAudioIOUnit` property listener.

Apple's
[`AVAudioEngineConfigurationChangeNotification`](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification)
documentation forbids deallocating an engine from its configuration callback.
Publishing a generation change allowed another thread to deallocate the engine
before the framework callback unwound.

Build 14 stops invalid sessions, detaches their private notification observer,
and retains the inert engine for the capture boundary's lifetime. `stop()`
releases prepared hardware resources. Deterministic coverage verifies that a
route change retires rather than deallocates the prior generation. The real
integration test now prefers a distinct physical input Device and also checks a
same-Device rate change when both are available.
