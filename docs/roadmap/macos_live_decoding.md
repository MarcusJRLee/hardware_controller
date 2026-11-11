---
title: Parakeet text arrives on macOS while you speak
priority: P1
rank: c
executor: agent
depends_on: []
specs: [docs/decisions/asr_runtime.md]
---

## Outcome

macOS Dictation shows Parakeet text during speech through pause-cut live
decoding in the speech service, matching the iOS cut rules, while the
recording stays the durable evidence.

## Acceptance

- The service decodes chunks cut at pauses as iOS does; any live failure
  falls back to transcribing the recording.
- Release latency, IPC, and HID soak gates still hold, reported with p50,
  p95, p99, max, and sample count.
- `scripts/check.sh` passes and the verify skill drives the Dictation
  journey on a signed install.
