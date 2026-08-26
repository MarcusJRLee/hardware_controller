# Local AI model evaluation

This is the acceptance record for the current Local AI Dictation prompt and
recommended Ollama model. Re-run it when the prompt, validator, context policy,
Ollama tag, quantization, or model digest changes.

```bash
HC_RUN_LOCAL_AI_MODEL_EVALUATION=1 \
  swift test --filter LocalAIModelEvaluationTest
```

The sanitized 17-case corpus covers prose, messages, email, lists,
self-correction, fillers, punctuation, technical terms, protected entities,
code-like text, prompt injection, Spanish, target capability, and nearby
context. Exact quality accepts only declared outputs. Semantic failures are
measured after deterministic polish and before delivery; production falls back
to raw text when validation fails.

Strict exact quality measures provider prose before the M3 structured-document
builder. Production additionally normalizes a validated consecutive ordinal
sequence into an ordered-list block and validates the canonical rendering again.

## Reference result

Reference Mac: Apple M5 Max, 128 GB unified memory, macOS 26.5.2. Prompt
revision: 5, Natural Style revision 1. Ollama context window: 2,048 tokens.
Samples include fixed-loopback health and digest validation.

| Measure | Qwen 3.5 4B | Qwen 3.5 9B | Apple On-Device |
| --- | ---: | ---: | ---: |
| Strict exact quality | 10/17 | 11/17 | 9/17 |
| Rejected semantic outputs | 0 | 1 | 2 |
| Warm p50 | 0.689 s | 0.982 s | 0.703 s |
| Warm p95 / p99 / maximum | 0.908 s | 1.262 s | 1.922 s |
| Warm samples | 17 | 17 | 17 |
| Fresh preparation p50 | 1.013 s | 1.176 s | 0.002 s |
| Fresh preparation p95 / p99 / maximum | 1.357 s | 2.430 s | 0.006 s |
| Fresh preparation samples | 5 | 5 | 5 |
| Maximum provider-reported model load | 0.109 s | 0.115 s | Not reported by Apple |
| Timeout or provider errors | 0/17 | 0/17 | 0/17 |
| Generated-token throughput | 79.2/s | 58.7/s | Not reported by Apple |
| Resident model allocation | 5.74 GB | 8.52 GB | OS-managed; not exposed |
| Model file | 3.39 GB | 6.59 GB | OS-managed |

Each Ollama fresh-preparation distribution uses five
unloaded-model→new-client→prepare samples and waits for confirmed unload between
samples. It does not flush the macOS file cache, so it is not a power-cycle
cold-start claim. Apple's row measures five fresh sessions; the OS-managed
system model cannot be explicitly unloaded. The app overlaps preparation with
speech and applies a separate three-second refinement deadline.

Evaluated Ollama identities:

- `qwen3.5:4b` — `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`
- `qwen3.5:9b` — `6488c96fa5faab64bb65cbd30d4289e20e6130ef535a93ef9a49f42eda893ea7`

## Selection

`qwen3.5:4b` is the recommended Ollama model. It is the only candidate that
met the zero-semantic-failure and one-second warm-refinement gates. Its 5.74 GB
resident allocation exceeds the 4 GB target; this is explicit and is not a
compatibility failure.

Pinned digest:

```text
2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd
```

Qwen 3.5 9B remains selectable as an unvalidated installed model. Its two
additional exact results did not justify 48% more resident allocation, a 38%
higher p95, and one rejected nearby-context copy. Apple On-Device remains a
supported provider, with validation and deterministic Edited fallback covering its rejected
outputs.

## Controller benchmark

The recommended model also passes through the production Local AI controller,
post-release deadline, validation, and transcript-writer boundary:

```bash
HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK=1 \
  swift test --filter measuresWarmReleaseToInsertionWithTheRecommendedModel
```

The benchmark explicitly prepares the selected model before timing. From an
initially unloaded model, the M4 spoken-edit controller's subsequent 17-case
warm run measured release-to-insertion p50 0.773 seconds and p95, p99, and
maximum 1.004 seconds.
Every case produced exactly one writer insertion. This is a synthetic target
test; physical Control, real microphone, recognition-finalization, and
external-app timing remain separate system checks.
