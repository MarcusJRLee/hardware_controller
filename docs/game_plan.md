# Game plan

Current source is an unreleased personal iteration whatever its version
metadata says. 1.4.0 build 15 is the last accepted private artifact
([release validation](release_validation.md)); 1.5.0 build 18 is the approved
QA candidate ([Builds and workflow](decisions/builds_and_workflow.md)).
Shipped behavior per journey is in [voice_cujs.md](voice_cujs.md).

## Quality gates

| Gate | Contract | Latest evidence |
| --- | --- | --- |
| HID dispatch | p50 ≤ 3 ms, p95 ≤ 8 ms, p99 ≤ 15 ms, max ≤ 30 ms over 10,000 transitions (max on dedicated hardware only); no loss or duplication. | p50 0.011, p95 0.016, p99 0.022, max 0.174 ms (`tenThousandTransitionSoakMeetsDispatchBudget`, every check). |
| Microphone start | Warm max ≤ 250 ms. | p50 48 ms, max 87 ms over five starts. |
| Local AI end to end | Warm release-to-insertion p95 ≤ 1.5 s. | Qwen 4B p50 1.108 s, p95 1.313 s over 19 samples. |
| Local AI refinement | Warm final-text-to-refined p95 ≤ 1 s. | **Open:** Qwen 4B p95 15.7 s including one timeout. |
| Local AI safety | No casing, list, or protected-content violation reaches delivery. | Fixed 19-case corpus passes the typed gate for every provider. |
| Local AI deadline | Fallback within 3 s after final speech. | Deterministic deadline and late-output tests. |
| History search | Warm 5,000-session p95 ≤ 250 ms. | p95 2.6 ms. |
| macOS speech | Release p95 ≤ 1 s; IPC p99 ≤ 10 ms; a service crash yields Apple text from the same audio ([Speech recognition runtime](decisions/asr_runtime.md)). | Parakeet v3 Q8_0 through the installed service: 84 s clip p95 408 ms; 0.0% synthetic WER; IPC p99 2.2 ms at 84 s; crash mid-decode recovers (`scripts/check_speech_engine.sh`, every install). |
| iOS ASR | File RTF ≤ 0.75 on the pinned corpus; bytes revalidated before load. | Whisper tiny.en Q8_0 RTF 0.004, Parakeet v3 Q8_0 RTF 0.005, WER 0.8% / 0.0% (synthetic corpus, M5 Max; `scripts/benchmark_asr.sh`). |
| Privacy | No speech logged; no remote-capable provider called; Ollama loopback only; iOS has no network code. | Provider-boundary, transport, and iOS source/capability scan on every check. |
| Docs | Docs describe current behavior; links resolve. | Reviewed with each PR. |

Local AI measurements: [local_ai_model_evaluation.md](local_ai_model_evaluation.md).
Reference-Mac results do not establish lower-tier support.

## Open work

Open evidence and next work are roadmap items in [`roadmap/`](roadmap/README.md).

## Risks

| Risk | Control |
| --- | --- |
| Unknown Infinity firmware | Match the narrow confirmed signature; reject changes. |
| Stateful Action survives failure | One ownership model with idempotent cleanup on every exit path. |
| Model changes meaning | Pinned digests, typed output, protected-content validation, deterministic fallback. |
| Local service becomes remote | Typed locality checked before invocation; numeric loopback; no proxies or redirects. |
| UI or inference delays input | Hot path off the main actor and independent of speech or model work. |
| Personal build mistaken for a release | Install and release promotion are separate, explicit steps. |
