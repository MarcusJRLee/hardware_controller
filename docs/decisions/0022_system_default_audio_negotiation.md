# 0022: Negotiate the System Default microphone

- **Status:** Accepted; implemented in current source
- **Date:** 2026-08-18
- **Amends:**
  [`0012_configuration_aware_audio_capture.md`](0012_configuration_aware_audio_capture.md),
  [`0015_app_local_microphone_selection.md`](0015_app_local_microphone_selection.md),
  and
  [`0017_same_route_audio_engine_recovery.md`](0017_same_route_audio_engine_recovery.md)

## Context

The capture boundary always assigned
`kAudioOutputUnitProperty_CurrentDevice`, including when the user selected
**System Default**. During the real 44.1→48 kHz built-in-input test, CoreAudio
reported the new route and the rebuilt input node reported 48 kHz, but
AVAudioEngine start failed with `kAudioUnitErr_FormatNotSupported`. The
explicit assignment forced AVFAudio's process-local graph instead of allowing
its default route to negotiate.

An explicit app-local Device still requires assignment so Hardware Controller
can differ from the system default.

## Decision matrix

| Criterion | Always pin | Never pin | Pin explicit selection only |
| --- | ---: | ---: | ---: |
| System Default rate negotiation | 1 | 5 | 5 |
| Independent app-local selection | 5 | 1 | 5 |
| Route-lease compatibility | 5 | 5 | 5 |
| Minimal system side effects | 3 | 5 | 5 |
| **Total** | **14** | **16** | **20** |

## Decision

- Leave the Audio Unit Device unset while following **System Default**.
- Assign `kAudioOutputUnitProperty_CurrentDevice` only for an explicit,
  currently available app-local Device UID.
- Continue leasing every engine to the effective CoreAudio Device, nominal
  rate, channel count, and observation generation.
- Continue using AVFAudio's negotiated tap format; the process-local format may
  differ from the hardware nominal rate while remaining valid.

## Consequences

System Default follows AVFAudio's negotiated route without an unnecessary
process-local pin. Explicit microphone selection remains independent from
other applications. Route changes retain the same invalidation, retirement,
and recovery behavior.

## Evidence

- A deterministic regression proves System Default produces no pinned Device
  ID and an explicit selection produces the effective Device ID.
- The real built-in microphone completed prepared 44.1→48 kHz activation,
  active 48→44.1 kHz invalidation, cleanup, and recovery in 0.972 seconds.
- The real explicit-input test preserved the system default and delivered 24
  buffers with a 104.649 ms maximum steady interval.
