# Game plan

## Current state

The source tree implements the native macOS controller, Profiles, exact
keyboard fallbacks, Local Dictation, and Local AI Dictation. It is an
unreleased personal iteration regardless of embedded version metadata. Version
1.4.0 build 15 remains the latest explicitly accepted private artifact; its
evidence is retained in [`release_validation.md`](release_validation.md).

| Area | Current state | Authority |
| --- | --- | --- |
| Device input | Exact Infinity 3 matching, exclusive ownership, three Controls, simultaneous input, and reconnect-safe decoding. | [`hardware/infinity_3.md`](hardware/infinity_3.md) |
| Actions | No Action, Local Dictation, Local AI Dictation, and Keyboard Shortcut with independent Hold and Toggle Bindings. | [`product_brief.md`](product_brief.md) |
| Local Dictation | On-device Apple recognition, adaptive live/final delivery, bounded finalization, and app-local microphone selection. | [`architecture.md`](architecture.md#action-registry-and-executors) |
| Local AI Dictation | Apple or fixed-loopback Ollama text refinement, dictionary, bounded context, validation, and raw fallback. | [`decisions/0020_local_ai_dictation.md`](decisions/0020_local_ai_dictation.md) |
| Model recommendation | Qwen 3.5 4B is digest-pinned from the fixed evaluation corpus. | [`decisions/0021_local_ai_model_selection.md`](decisions/0021_local_ai_model_selection.md) |
| Profiles | Transactional named Profiles with independent per-Device setups and active-Action cleanup. | [`decisions/0014_multi_profile_device_configuration.md`](decisions/0014_multi_profile_device_configuration.md) |
| Application | Controller, Profiles, and General in one native foreground window with Dock and menu-bar presence. | [`ux_spec.md`](ux_spec.md) |
| Release | Version 1.4.1 build 17 is installed as an unreleased personal QA candidate; routine installs preserve both values and no release promotion is authorized. | [`decisions/0023_stable_personal_build_metadata.md`](decisions/0023_stable_personal_build_metadata.md) |
| Public source | Open source under Apache License 2.0 with Marcus John Rice Lee as copyright owner, inbound Apache contributions, provisional Signal Bridge identity, and active GitHub security controls. | [`decisions/0028_apache_open_source_and_contributions.md`](decisions/0028_apache_open_source_and_contributions.md) |

## Quality gates

| Gate | Contract | Current automated evidence |
| --- | --- | --- |
| HID dispatch | p50 ≤ 3 ms, p95 ≤ 8 ms, p99 ≤ 15 ms, max ≤ 30 ms across 10,000 transitions; no loss or duplication. | p50 0.013 ms, p95 0.024 ms, p99 0.046 ms, max 0.257 ms; 10,000 ordered dispatches. |
| Microphone activation | Warm maximum ≤ 250 ms. | p50 48.118 ms, p95/p99/max 87.050 ms across five starts; one-time preparation 149.539 ms. |
| Local AI semantic safety | No accepted provider output may corrupt protected content; invalid output falls back raw once. | Fixed 17-case corpus and validator tests. |
| Local AI refinement | Warm raw-final-to-refined p95 ≤ 1 s on the reference Mac. | Qwen 3.5 4B p95 0.935 s. |
| Local AI end to end | Warm release-to-insertion p95 ≤ 1.5 s on the reference Mac. | Prewarmed production-controller benchmark p95 1.052 s. |
| Local AI deadline | Preparation plus generation must fall back within three seconds after final speech text. | Deterministic deadline and late-output tests. |
| Privacy | No speech content is persisted or logged; Ollama cannot reach a nonloopback endpoint. | Static scan plus fixed-endpoint transport tests. |
| Documentation | Canonical docs describe current behavior and all links resolve. | All local links resolve. |

Reference Local AI measurements and reproduction commands are in
[`local_ai_model_evaluation.md`](local_ai_model_evaluation.md). Results from a
high-end reference Mac do not establish lower-tier support.

The canonical `/Applications/Hardware Controller.app` contains current-source
version 1.4.1 build 17 under `com.longdevity.hardwarecontroller`, signed by the
private Apple Development Team configured in `.env.local`. Its
installed binary is byte-identical to the verified candidate and passed strict
signature, audio-input entitlement, hardened-runtime, architecture, and
Apple-only dependency checks. In normal mode it runs from the canonical path,
matches the connected VEC USB Footpedal, reports existing permissions ready,
and preserves the accepted Profile. Both provider tests passed before install.
With Ollama **Until app quits**, the app-owned model reported indefinite
retention while the candidate ran and no resident model after quit. The
physical Control has not been actuated against build 17.

## Remaining evidence

These checks are required before claiming their corresponding environment or
distribution scope:

| Check | Required evidence |
| --- | --- |
| Physical Dictation handoff | Switch between Local and Local AI Dictation, disconnect while active, replace the Profile, sleep/wake, and confirm one cleanup per session. |
| External applications | Exercise native live fields, web fields, Terminal, Cursor terminal, focus changes, caret changes, and secure-field rejection with both Dictation Actions. |
| Lower-tier Apple silicon | Measure Apple and recommended Ollama quality, cold/warm latency, and memory on the lowest intended supported Mac. |
| External microphone | Sustain capture from a distinct app-selected input without changing the system default. |
| macOS 15–25 | Run permissions, legacy recognition, insertion, and lifecycle acceptance; Local AI must use Ollama because Apple Foundation Models require macOS 26. |
| Accessibility | Complete keyboard navigation, VoiceOver spoken-output, increased-contrast, reduced-motion, and large-text review. |
| Device lifecycle | Exercise long holds, simultaneous Controls, hub reconnect, logout/login, and pointer-passthrough rejection. |
| Clean account | Rehearse install, permissions, Ollama absence/setup, configuration, relaunch, update, and removal. |
| Future ownership | Form Longdevity LLC, execute a signed copyright assignment, then update the notice and licensing authority through a separate decision and PR. |
| Public distribution | Obtain Developer ID and notary credentials, then complete the gated free-DMG workflow and clean-install evidence in [`public_distribution.md`](public_distribution.md). |

## Verification baseline

```bash
scripts/check.sh
```

Run the opt-in model evaluation and controller benchmark when the prompt,
validator, context policy, catalog, model tag, or digest changes. Run the
hardware, microphone, speech, focused-field, web, foreground-event, and
full-pipeline checks from [`README.md`](../README.md#opt-in-system-verification)
when their dependencies are available.

## Release boundary

- Treat all current-source version metadata as unreleased until explicitly
  approved.
- Sign every Applications build with the private Apple Development identity and
  verify its Team against `HC_EXPECTED_TEAM_ID` before launch.
- After every repository change, replace the single canonical
  `/Applications/Hardware Controller.app` with the signed current source,
  verify it, then launch that exact bundle.
- Preserve both marketing version and build number unless the user explicitly
  approves their exact replacement values.
- Do not run the release script, create artifacts, tag, or publish a GitHub
  Release without explicit approval for that exact version.
- Preserve later-schema Profile and preference files unchanged; require a newer
  app rather than treating them as corruption.

## Principal risks

| Risk | Control |
| --- | --- |
| Unknown Infinity firmware | Match the narrow confirmed signature and reject changed collections. |
| Older speech runtime drift | Require on-device recognition and retain the macOS 15–25 gate. |
| Stateful Action survives failure | Centralize ownership and run idempotent cleanup on handoff, disconnect, sleep, permission loss, Profile change, and shutdown. |
| Model changes meaning | Pin validated digests, use typed output, enforce protected-content and semantic bounds, then fall back raw. |
| Local service becomes a remote path | Fix Ollama to numeric loopback, disable redirects/proxies, and reject cloud-only model identities. |
| UI or inference delays input | Keep HID decoding and Action dispatch off the main actor and outside speech/model work. |
| Personal artifact is mistaken for a release | Keep install and release promotion explicit and retain private signing evidence outside source control. |
| Modified build is mistaken for official | Keep canonical-project identification explicit and require official Releases to pass the gated notarization workflow. |

Promote a version only when its intended scope has current automated, physical,
accessibility, signing, installation, privacy, and performance evidence and the
user explicitly approves that exact version.
