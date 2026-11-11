---
title: Dictation works on macOS 15 through 25
priority: P3
rank: b
executor: human
depends_on: []
specs: [docs/decisions/macos_speech_capture.md]
---

## Outcome

Permissions, legacy recognition, insertion, and lifecycle work on macOS 15–25,
with Local AI through Ollama only.

## Acceptance

- Human: run the Dictation journeys on a macOS 15–25 machine or VM.
- Results land in `docs/voice_cujs.md`.
