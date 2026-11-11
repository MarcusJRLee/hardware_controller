---
title: Moonshine streaming is measured against Parakeet
priority: P3
rank: d
executor: agent
depends_on: [macos_live_decoding]
specs: [docs/decisions/asr_runtime.md]
---

## Outcome

The speech runtime record says whether Moonshine streaming beats pause-cut
Parakeet on latency and accuracy, with numbers.

## Acceptance

- Moonshine and Parakeet live decoding run on the same pinned corpus,
  reporting WER and time-to-text p50, p95, p99, max, and sample count.
- The result and decision land in `docs/decisions/asr_runtime.md`.
