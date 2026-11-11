---
title: iOS formats Dictation with a local model
priority: P2
rank: c
executor: agent
depends_on: []
specs: [docs/decisions/local_ai_formatting.md]
---

## Outcome

iOS formatting uses whichever of a small local model (0.8B class) and Apple
Foundation Models beats the deterministic fallback, or the record says why
neither does.

## Acceptance

- Both candidates are benchmarked against the fallback on the fixed corpus
  for safety violations, quality, latency, and memory on iPhone.
- The choice and its numbers land in `docs/decisions/local_ai_formatting.md`.
