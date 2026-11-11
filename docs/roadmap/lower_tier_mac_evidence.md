---
title: Dictation is measured on the lowest supported Mac
priority: P3
rank: a
executor: human
depends_on: []
specs: [docs/local_ai_model_evaluation.md]
---

## Outcome

Apple and Ollama quality, latency, and memory are known on the lowest
supported Mac, so support claims rest on measurement rather than the
reference Mac.

## Acceptance

- Human: run the evaluation scripts on that Mac.
- Results land in `docs/local_ai_model_evaluation.md`.
