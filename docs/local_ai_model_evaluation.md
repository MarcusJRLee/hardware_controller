# Local AI model evaluation

This is the acceptance record for the current Local AI Dictation prompt. Re-run
it when the prompt, validator, context policy, model tag, quantization, or digest
changes.

```bash
HC_RUN_LOCAL_AI_MODEL_EVALUATION=1 \
  swift test --filter LocalAIModelEvaluationTest

HC_RUN_LOCAL_AI_MODEL_EVALUATION=1 \
HC_LOCAL_AI_EVALUATION_MODEL=qwen3.5:4b \
  swift test --filter LocalAIModelEvaluationTest
```

The sanitized 19-case corpus covers prose, messages, email, typed lists,
self-correction, fillers, punctuation, technical terms, protected entities,
code-like text, prompt injection, Spanish, target capability, nearby context,
strict lowercase, and grocery-list intent.

Exact output matching is diagnostic. The semantic gate permits at most 15% of
cases to fail semantic validation and at most 10% provider errors. Final
candidates permit no protected-token, requested-casing, or required-structure
failure. Production applies deterministic casing/list normalization, validates
the canonical rendering, and delivers Edited fallback once on rejection.

## Prompt 6 reference result

Reference Mac: Apple M5 Max, 128 GB unified memory, macOS 26.5.2. Prompt
revision: 6, Natural Style revision 1. Ollama context window: 2,048 tokens.
Samples include fixed-loopback health and digest validation.

| Measure | Qwen 3.5 4B | Qwen 3.5 9B | Apple On-Device |
| --- | ---: | ---: | ---: |
| Exact quality | 8/19 | 12/19 | 7/19 |
| Semantic failures | 2/19 | 0/19 | 1/19 |
| Semantic gate | Pass | Pass | Pass |
| Provider errors | 1/19 | 0/19 | 0/19 |
| Warm p50 | 1.099 s | 1.689 s | 0.775 s |
| Warm p95 / p99 / maximum | 15.739 s | 1.952 s | 1.977 s |
| Warm samples | 19 | 19 | 19 |
| Fresh preparation p50 | 1.152 s | 1.921 s | 0.002 s |
| Fresh preparation p95 / p99 / maximum | 2.481 s | 2.540 s | 0.006 s |
| Fresh preparation samples | 5 | 5 | 5 |
| Maximum provider-reported model load | 0.177 s | 0.116 s | Not reported |
| Generated-token throughput | 72.1/s | 58.3/s | Not reported |
| Resident model allocation | 5.74 GB | 8.52 GB | OS-managed |
| Model file | 3.39 GB | 6.59 GB | OS-managed |

The 4B maximum is one fixed-loopback provider timeout. The production controller
has a separate three-second preparation-plus-generation deadline, so it would
deliver deterministic Edited fallback earlier. The prompt-6 result does not
meet the legacy one-second p95 refinement target.

Each Ollama preparation distribution uses five
unloaded-model→new-client→prepare samples and confirms unload between samples.
It does not flush the macOS file cache. Apple's row measures five fresh sessions;
the OS-managed model cannot be explicitly unloaded.

Evaluated Ollama identities:

- `qwen3.5:4b` — `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`
- `qwen3.5:9b` — `6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7`

## Interpretation

Qwen 3.5 9B produced the most exact prompt-6 outputs and no semantic rejection,
but used 48% more resident memory and was slower. Apple remained fastest at
p50 and had one bounded semantic rejection. Qwen 3.5 4B remained within the
flexible semantic gate but had two semantic rejections and one provider timeout.

This run does not supersede the digest-pinned 4B recommendation in
[`0021_local_ai_model_selection.md`](decisions/0021_local_ai_model_selection.md).
That decision needs a separate lower-tier and production-controller comparison
before changing the default. The result reinforces that a model swap alone
cannot replace deterministic casing, typed list normalization, validation, and
fallback.

## Prompt 6 production-controller benchmark

The benchmark explicitly prepared Qwen 3.5 4B before timing all 19 prompt-6
cases through the production controller:

```bash
HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK=1 \
  swift test --filter measuresWarmReleaseToInsertionWithTheRecommendedModel
```

It measured release-to-insertion p50 1.108 seconds and p95/p99/maximum 1.313
seconds with one insertion per case. The warm p95 passes the 1.5-second gate.
The controller result includes deterministic normalization, validation,
fallback, and insertion; it does not replace the provider-only latency row.
