---
title: Local AI refinement meets its 1 s p95
priority: P1
rank: d
executor: agent
depends_on: []
specs: [docs/decisions/local_ai_formatting.md, docs/local_ai_model_evaluation.md]
---

## Outcome

Warm final-text-to-refined latency has p95 ≤ 1 s on the reference Mac. Qwen
3.5 4B currently measures 15.7 s p95, driven by one provider timeout.

## Acceptance

- The timeout's cause is found and fixed, or the default model or provider
  changes, without weakening the safety gate.
- `docs/local_ai_model_evaluation.md` reports p50, p95, p99, max, and sample
  count, and the Quality gates row in `docs/game_plan.md` is no longer open.
