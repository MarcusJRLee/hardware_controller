# 0017: Same-route audio-engine recovery

- **Status:** Accepted
- **Date:** 2026-08-05
- **Amends:**
  [`0012_configuration_aware_audio_capture.md`](0012_configuration_aware_audio_capture.md)
  and
  [`0015_app_local_microphone_selection.md`](0015_app_local_microphone_selection.md)

## Context

Pinning Hardware Controller's Audio Unit to an explicit microphone can make
AVFAudio replace its process-local default aggregate with the selected physical
Device. AVFAudio then posts an engine-configuration notification and stops the
engine even though CoreAudio still reports the same effective Device, rate, and
channel count. Treating every notification as a route change produced a false
"Microphone input changed" failure on every Dictation attempt.

The microphone picker also exposed AVFAudio's process-scoped aggregate. Its UID
contains a process identifier, so it is not a durable user selection.

## Decision matrix

| Criterion | Fail every notification | Ignore unchanged notifications | Verify route and restart once |
| --- | ---: | ---: | ---: |
| Avoids the false route failure | 1 | 5 | 5 |
| Restores an engine stopped by AVFAudio | 1 | 1 | 5 |
| Preserves true route-change safety | 5 | 2 | 5 |
| Bounds framework recovery | 5 | 1 | 5 |
| Keeps work off the AVFAudio callback | 5 | 5 | 5 |
| **Total** | **17** | **14** | **25** |

## Decision

- Compare Device, nominal rate, channels, and observation generation when an
  active engine posts a configuration notification.
- Fail active capture exactly once when any route component changed or cannot
  be read.
- For an unchanged route, serialize one prepare/start recovery attempt on the
  engine's private queue. Never mutate or release the engine on AVFAudio's
  notification callback.
- Fail once and discard the generation if recovery throws or another unchanged
  notification arrives before the active session ends.
- Exclude UIDs beginning with `CADefaultDeviceAggregate-` from persisted
  microphone choices. Continue allowing stable user-created aggregate Devices.

## Consequences

- Explicit physical-device selection survives AVFAudio's expected graph
  transition without ending Dictation.
- Genuine Device, rate, or channel changes retain the conservative failure and
  next-activation rebuild contract.
- Recovery cannot loop indefinitely if AVFAudio repeatedly invalidates the
  graph.
- The microphone picker contains only choices whose UIDs can survive relaunch.

## Evidence

- Deterministic tests distinguish unchanged-route recovery, silently changed
  routes, redundant failures, failed recovery, and fresh-generation retry.
- The explicit built-in Device delivered 24 consecutive real buffers after
  pinning without changing the system default. Across 23 steady intervals,
  p50 was 96.084 ms, p95 was 106.745 ms, p99 and maximum were 106.771 ms.
