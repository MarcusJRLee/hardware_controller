---
title: Dictation hands off cleanly on the physical Infinity
priority: P1
rank: b
executor: human
depends_on: []
specs: [docs/voice_cujs.md]
---

## Outcome

Dictation on the real pedal survives every handoff with exactly one cleanup:
switching Dictation Actions, disconnecting while active, switching Profiles,
and sleep/wake.

## Acceptance

- Human: run each handoff on the installed build with the Infinity attached.
- Each one ends with one cleanup, no stuck recording, and no duplicate
  insertion; results land in the journey proofs in `docs/voice_cujs.md`.
