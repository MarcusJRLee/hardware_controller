---
title: Voice Input holds up on a physical iPhone
priority: P2
rank: g
executor: human
depends_on: []
specs: [docs/decisions/ios_capture.md]
---

## Outcome

Voice Input survives kill, suspend, and upgrade, system surfaces, host
rejection, and interruptions, and live decoding's thermal, energy, and
Parakeet memory costs are measured on device.

## Acceptance

- Human: run each lifecycle case and an Instruments energy and memory trace
  on a physical iPhone.
- Results land in `docs/decisions/ios_capture.md` and `docs/voice_cujs.md`.
