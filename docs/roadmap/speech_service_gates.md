---
title: The macOS speech service's open gates are measured
priority: P2
rank: a
executor: agent
depends_on: []
specs: [docs/decisions/asr_runtime.md, scripts/check_speech_engine.sh]
---

## Outcome

The Hot path and Memory gates of the speech runtime close: the HID soak
budget holds while the service decodes, crashes, and relaunches, and service
exit returns its memory footprint.

## Acceptance

- A soak runs 10,000 transitions while the service is killed mid-decode and
  relaunched, and meets the HID dispatch budget with no loss or duplication.
- Resident memory before load, after load, and after exit is measured.
- Both results land in the Gates table of `docs/decisions/asr_runtime.md`.
