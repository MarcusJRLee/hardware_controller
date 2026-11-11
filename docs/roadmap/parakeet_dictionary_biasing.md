---
title: Parakeet recognizes Dictionary terms
priority: P2
rank: b
executor: agent
depends_on: []
specs: [docs/decisions/asr_runtime.md]
---

## Outcome

Dictionary terms bias Parakeet's decoding through contextual biasing, so
names and jargon come out right before replacements run. Today Parakeet
ignores recognition hints.

## Acceptance

- Biasing measurably lowers term error on a fixed corpus of Dictionary terms
  without raising WER elsewhere; method and numbers are recorded.
- The Dictionary view no longer says Parakeet ignores hints.
