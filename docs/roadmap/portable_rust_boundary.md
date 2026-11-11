---
title: The Rust core is ready for other platforms
priority: P3
rank: e
executor: agent
depends_on: []
specs: [docs/decisions/portable_voice_engine.md]
---

## Outcome

No Apple type crosses the Rust boundary, and the record documents the
Android, Windows, and Linux seams without building them.

## Acceptance

- A check fails if an Apple type enters the Rust crates or the C header.
- `docs/decisions/portable_voice_engine.md` names each platform seam.
