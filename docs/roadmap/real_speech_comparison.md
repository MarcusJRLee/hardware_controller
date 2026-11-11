---
title: Parakeet matches Apple on the owner's real speech
priority: P1
rank: a
executor: human
depends_on: []
specs: [docs/decisions/asr_runtime.md]
---

## Outcome

The Real speech gate in the speech runtime record closes: Parakeet's word
error rate on the owner's own recordings is no worse than Apple's, or the
default engine changes. Synthetic corpora cannot close this gate.

## Acceptance

- Human: record a spoken corpus (dictation, names, numbers, Dictionary
  terms) and transcribe it with both engines through the installed app.
- Measured WER per engine, sample count, and the decision land in the Gates
  table of `docs/decisions/asr_runtime.md`.
