# Game plan

Current source is an unreleased personal iteration whatever its version
metadata says. 1.4.0 build 15 is the last accepted private artifact
([release validation](release_validation.md)); 1.5.0 build 18 is the approved
QA candidate ([0051](decisions/0051_unreleased_voice_integration_build.md)).
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
| iOS ASR | File RTF ≤ 0.75 on the pinned corpus; bytes revalidated before load. | Whisper tiny.en Q8_0 RTF 0.004, Parakeet v3 Q8_0 RTF 0.005, WER 0.8% / 0.0% (synthetic corpus, M5 Max; `scripts/benchmark_asr.sh`). |
| Privacy | No speech logged; no remote-capable provider called; Ollama loopback only; iOS has no network code. | Provider-boundary, transport, and iOS source/capability scan on every check. |
| Docs | Docs describe current behavior; links resolve. | Reviewed with each PR. |

Local AI measurements: [local_ai_model_evaluation.md](local_ai_model_evaluation.md).
Reference-Mac results do not establish lower-tier support.

## Open evidence

| Check | Needed |
| --- | --- |
| Physical Dictation handoff | Switch Dictation Actions, disconnect while active, switch Profiles, sleep/wake; one cleanup each. |
| External apps | Native, web, Terminal, Cursor, focus/caret changes, secure-field rejection, both Dictation Actions. |
| Lower-tier Macs | Apple and Ollama quality, latency, and memory on the lowest supported Mac. |
| macOS 15–25 | Permissions, legacy recognition, insertion, lifecycle; Local AI via Ollama only. |
| Accessibility | Keyboard, VoiceOver, contrast, reduced motion, large text. |
| Device lifecycle | Long holds, simultaneous Controls, hub reconnect, logout/login. |
| iOS physical | Kill/suspend/upgrade, system surfaces, host rejection, interruption, live-decoding thermals and energy, Parakeet memory. |
| Clean account | Install, permissions, Ollama setup, update, removal. |
| Public release | Developer ID and notarization ([public_distribution.md](public_distribution.md)). |
| Ownership | Longdevity LLC formation and copyright assignment, by separate decision. |

## Next work

- macOS native ASR (Parakeet through transcribe.cpp) in an XPC service, so a
  kernel fault cannot take down the Device hot path.
- Portability: keep Apple types out of the Rust boundary; document Android,
  Windows, and Linux seams without building them. Remote providers need a new
  privacy decision first.
- Formatting on iOS: a small local model (0.8B class) or Apple Foundation
  Models, benchmarked against the deterministic fallback.

## Risks

| Risk | Control |
| --- | --- |
| Unknown Infinity firmware | Match the narrow confirmed signature; reject changes. |
| Stateful Action survives failure | One ownership model with idempotent cleanup on every exit path. |
| Model changes meaning | Pinned digests, typed output, protected-content validation, deterministic fallback. |
| Local service becomes remote | Typed locality checked before invocation; numeric loopback; no proxies or redirects. |
| UI or inference delays input | Hot path off the main actor and independent of speech or model work. |
| Personal build mistaken for a release | Install and release promotion are separate, explicit steps. |
