# 0021: Recommend digest-pinned Qwen 3.5 4B

- **Status:** Accepted; implemented in current source
- **Date:** 2026-08-17
- **Follows:** [`0020_local_ai_dictation.md`](0020_local_ai_dictation.md)

## Context

Local AI Dictation needs one default Ollama recommendation without preventing a
user from selecting other installed local models. The original 4 GB memory
goal is a target rather than a cutoff. Quality, semantic safety, warm latency,
and resident memory must be measured through one fixed sanitized corpus before
pinning a model.

Prompt revision 4, a 2,048-token Ollama context window, deterministic
generation, deterministic transcript polish, and the production validator were
evaluated on the reference Apple M5 Max Mac with 128 GB unified memory.

## Decision matrix

| Criterion | Qwen 3.5 4B | Qwen 3.5 9B | Apple On-Device |
| --- | ---: | ---: | ---: |
| Strict exact outputs | 9/17 | 11/17 | 8/17 |
| Validator-rejected semantic outputs | 0 | 1 | 2 |
| Warm p95 | 0.935 s | 1.294 s | 1.600 s |
| Resident model allocation | 5.74 GB | 8.52 GB | OS-managed |
| Model file | 3.39 GB | 6.59 GB | OS-managed |
| Ollama recommendation | Selected | Unvalidated option | Not an Ollama model |

The production controller and writer benchmark for Qwen 3.5 4B measured 17
prewarmed release-to-insertion samples at p50 0.838 seconds and
p95/p99/maximum 1.052 seconds with one insertion per sample.

## Decision

- Recommend `qwen3.5:4b` and pin digest
  `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`.
- Label the model recommended only when the installed digest matches exactly.
- Keep Qwen 3.5 9B and other installed local models selectable only after their
  current digest is explicitly pinned; do not label them validated.
- Keep Apple On-Device as a supported independent provider. Its output passes
  through the same validator and raw-fallback boundary.
- Default Ollama retention to five minutes. Allow process-lifetime retention as
  an explicit latency/memory tradeoff.
- Treat 5.74 GB as the measured reference allocation and disclose that it
  exceeds the 4 GB target.
- Re-run the fixed corpus and controller benchmark when the prompt revision,
  validator, context policy, model tag, quantization, or digest changes.

## Consequences

The selected model meets the zero-semantic-rejection and one-second warm
refinement gates while using materially less memory than the 9B candidate. The
two additional exact 9B results do not justify 48% more resident memory, a
38% higher p95, and one nearby-context-copy rejection. Reference results do not
claim lower-tier Apple-silicon performance; that remains a physical evidence
gate.

The complete corpus method, cold-start qualification, throughput, and
reproduction commands are in
[`../local_ai_model_evaluation.md`](../local_ai_model_evaluation.md).
