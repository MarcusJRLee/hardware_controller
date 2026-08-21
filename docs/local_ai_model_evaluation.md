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

## Reference result

Reference Mac: Apple M5 Max, 128 GB unified memory, macOS 26.5.2. Prompt
revision: 4. Ollama context window: 2,048 tokens. Samples include fixed-loopback
health and digest validation.

| Measure | Qwen 3.5 4B | Qwen 3.5 9B | Apple On-Device |
| --- | ---: | ---: | ---: |
| Strict exact quality | 9/17 | 11/17 | 8/17 |
| Rejected semantic outputs | 0 | 1 | 2 |
| Warm p50 | 0.706 s | 0.920 s | 0.521 s |
| Warm p95 / p99 / maximum | 0.935 s | 1.294 s | 1.600 s |
| Warm samples | 17 | 17 | 17 |
| Fresh preparation p50 | 1.027 s | 1.139 s | 0.002 s |
| Fresh preparation p95 / p99 / maximum | 1.043 s | 1.883 s | 0.007 s |
| Fresh preparation samples | 5 | 5 | 5 |
| Maximum provider-reported model load | 0.110 s | 0.126 s | Not reported by Apple |
| Timeout or provider errors | 0/17 | 0/17 | 0/17 |
| Generated-token throughput | 74.4/s | 59.2/s | Not reported by Apple |
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
supported provider, with validation and raw fallback covering its rejected
outputs.

## Controller benchmark

The recommended model also passes through the production Local AI controller,
post-release deadline, validation, and transcript-writer boundary:

```bash
HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK=1 \
  swift test --filter measuresWarmReleaseToInsertionWithTheRecommendedModel
```

The benchmark explicitly prepares the selected model before timing. From an
initially unloaded model, the subsequent 17-case warm run measured
release-to-insertion p50 0.838 seconds and p95, p99, and maximum 1.052 seconds.
Every case produced exactly one writer insertion. This is a synthetic target
test; physical Control, real microphone, recognition-finalization, and
external-app timing remain separate system checks.
