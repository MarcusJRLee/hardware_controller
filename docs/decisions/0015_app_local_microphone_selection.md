# 0015: App-local microphone selection

- **Status:** Accepted
- **Date:** 2026-08-03
- **Amends:**
  [`0012_configuration_aware_audio_capture.md`](0012_configuration_aware_audio_capture.md)

## Context

Local Dictation followed the system default input. Users with built-in, USB,
display, aggregate, or wireless inputs need a durable app-specific choice
without changing audio routing for every other application.

CoreAudio object IDs are ephemeral runtime identifiers and can change across
reconnects or boots. Device UIDs are persistent on one Mac. A saved Device can
still be temporarily absent.

## Decision matrix

| Criterion | System default only | Change the system default | App-local Device UID |
| --- | ---: | ---: | ---: |
| Independent from other apps | 1 | 1 | 5 |
| Survives relaunch and reboot | 5 | 4 | 5 |
| Handles temporary disconnect | 5 | 3 | 5 |
| Preserves configuration leases | 5 | 3 | 5 |
| Avoids new dependencies | 5 | 5 | 5 |
| **Total** | **21** | **16** | **25** |

## Decision

- Add **System Default** plus every current CoreAudio Device with input
  channels to General.
- Persist the selected Device UID and last known display name in local
  schema-2 application preferences. Never persist an ephemeral CoreAudio
  object ID.
- Pin only Hardware Controller's input Audio Unit through
  `kAudioOutputUnitProperty_CurrentDevice`. Never change the system-wide
  default input.
- Include the effective Device, sample rate, channels, and observation
  generation in the existing capture lease.
- Cancel active Dictation and clear Action ownership before applying a new
  selection. Rebuild authorized warm resources against the new route.
- If the saved Device is absent, retain the preference, show it as unavailable,
  and capture from System Default. Automatically use the saved Device again
  after it reconnects.
- Observe both the CoreAudio Device list and effective Device configuration.
  Fail active capture once when the effective route changes.
- Keep discovery, selection, capture, preferences, and migration local. Add no
  network capability or runtime dependency.

## Consequences

- Local Dictation can use a microphone independently from other applications.
- Reconnecting a preferred Device restores it without another user edit.
- A selection change intentionally ends the current Dictation session.
- Release validation must capture from an explicit Device and prove that the
  system default input remains unchanged.
