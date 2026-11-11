---
title: Dictation inserts correctly in external apps
priority: P2
rank: d
executor: human
depends_on: []
specs: [docs/decisions/macos_text_delivery.md]
---

## Outcome

Both Dictation Actions insert correctly in native, web, Terminal, and Cursor
text fields, follow focus and caret changes, and refuse secure fields.

## Acceptance

- Human: run both Dictation Actions in each app class on the installed build.
- Results land in the journey proofs in `docs/voice_cujs.md`.
