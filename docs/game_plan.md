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
| Local AI Dictation | Apple or fixed-loopback Ollama text refinement, spoken edits, Dictionary, bounded context, validation, and deterministic Edited fallback. | [`decisions/0020_local_ai_dictation.md`](decisions/0020_local_ai_dictation.md) |
| Voice M1 tracer | Local AI Dictation tees immutable audio off the capture path, inserts once, and atomically stores one CAF plus separate final text stages in SQLite. | [`voice_cujs.md`](voice_cujs.md#m1--hold-to-dictate-and-recover) |
| Voice M2 trigger | One opt-in machine-wide exact chord starts Local AI Dictation immediately, supports hold or double-press latch, finishes once, cancels on interruption, and reports reservation conflicts. | [`voice_cujs.md`](voice_cujs.md#m2--latch-a-long-prompt) |
| Voice M3 formatting | Five versioned Styles produce validated evidence-backed paragraph/list blocks; one renderer preserves multiline structure or safely flattens it, and Verbatim skips the model. | [`voice_cujs.md`](voice_cujs.md#m3--format-for-purpose) |
| Voice M4 spoken edits | Exact backtrack, paragraph, numbered-list, and literal commands produce persisted replayable operations before formatting; ambiguous or inapplicable phrases remain text. | [`voice_cujs.md`](voice_cujs.md#m4--backtrack-explicitly) |
| Voice M5 ownership guard | Local AI preserves its captured route, rejects nonempty or changed carets, distinguishes process/secure/focus/caret invalidation, withholds later mutations, and stores a typed reason. | [`voice_cujs.md`](voice_cujs.md#m5--preserve-ownership-when-the-target-changes) |
| Voice M6 History | A fourth native destination searches every text stage, exposes immutable provenance and timed audio, and appends corrections, retranscriptions, reformats, and explicit re-delivery outcomes without rewriting earlier results. Export, pin, and transactional delete are available. | [`voice_cujs.md`](voice_cujs.md#m6--browse-and-reuse-history) |
| Voice M7 retention | Versioned age, byte, count, and low-disk rules expire only eligible audio, retain searchable transcript evidence, protect active/pinned/recovery artifacts, and disclose typed reasons. | [`decisions/0031_bounded_voice_history_audio.md`](decisions/0031_bounded_voice_history_audio.md) |
| Voice M8 recovery | Startup deterministically repairs partial, orphan, and expiration-quarantine audio; isolates corrupt rows; preserves a corrupt database; retains text on audio failure; and exposes recovered audio for playback/retranscription for 24 hours. | [`decisions/0032_voice_history_crash_recovery.md`](decisions/0032_voice_history_crash_recovery.md) |
| Voice M9 local enforcement | Typed provider locality rejects remote-capable adapters before invocation; formatting degrades to validated Edited text; ASR loss preserves captured audio without target mutation. | [`decisions/0033_local_only_voice_enforcement.md`](decisions/0033_local_only_voice_enforcement.md) |
| Voice M10 trigger convergence | Physical Controls, Hold/latch Voice chords, and the menu-bar record action submit typed commands to one Local AI session workflow without changing History or delivery meaning. | [`decisions/0034_voice_trigger_convergence.md`](decisions/0034_voice_trigger_convergence.md) |
| Voice M11 portable tracer | The Swift baseline and dependency-free Rust retention planner pass one CUJ fixture; a versioned caller-owned C ABI passes layout and real-consumer checks. | [`decisions/0035_portable_voice_c_abi.md`](decisions/0035_portable_voice_c_abi.md) |
| Voice M12 audio import | History streams a user-selected recording into one bounded app-owned CAF, runs local ASR and Style formatting, preserves typed provenance, and retains honest transcript-only or audio-only fallbacks. | [`decisions/0036_imported_voice_audio.md`](decisions/0036_imported_voice_audio.md) |
| Model recommendation | Qwen 3.5 4B is digest-pinned from the fixed evaluation corpus. | [`decisions/0021_local_ai_model_selection.md`](decisions/0021_local_ai_model_selection.md) |
| Profiles | Transactional named Profiles with independent per-Device setups and active-Action cleanup. | [`decisions/0014_multi_profile_device_configuration.md`](decisions/0014_multi_profile_device_configuration.md) |
| Application | Controller, History, Profiles, and General in one native foreground window with Dock and menu-bar presence. | [`ux_spec.md`](ux_spec.md) |
| Release | Version 1.4.1 build 17 is installed as an unreleased personal QA candidate; routine installs preserve both values and no release promotion is authorized. | [`decisions/0023_stable_personal_build_metadata.md`](decisions/0023_stable_personal_build_metadata.md) |
| Public source | Open source under Apache License 2.0 with Marcus John Rice Lee as copyright owner, inbound Apache contributions, provisional Signal Bridge identity, and active GitHub security controls. | [`decisions/0028_apache_open_source_and_contributions.md`](decisions/0028_apache_open_source_and_contributions.md) |

## Approved next program

The local Voice expansion is accepted; macOS M1–M12 are implemented across the
current stacked branches. macOS and iOS are the active roadmap; Android,
Windows, and Linux remain architectural line-of-sight platforms; web and mobile
web are deferred. The acceptance and execution authorities are:

| Authority | Purpose |
| --- | --- |
| [`decisions/0029_local_voice_platform_expansion.md`](decisions/0029_local_voice_platform_expansion.md) | Durable product, platform, portability, retention, and delivery choices. |
| [`voice_cujs.md`](voice_cujs.md) | CUJ-first behavioral and testing contract. |
| [`voice_platform_design.md`](voice_platform_design.md) | Model, runtime, iOS keyboard, storage, performance, and milestone design. |
| [`voice_implementation_goal_prompt.md`](voice_implementation_goal_prompt.md) | Autonomous worktree/PR execution contract and definition of done. |

Implementation integrates focused vertical PRs into `dev`. `main`, release
metadata, tags, distribution artifacts, and store submission remain unchanged
until the user verifies the finished `dev` state and separately approves
promotion.

## Quality gates

| Gate | Contract | Current automated evidence |
| --- | --- | --- |
| HID dispatch | p50 ≤ 3 ms, p95 ≤ 8 ms, p99 ≤ 15 ms, max ≤ 30 ms across 10,000 transitions; no loss or duplication. | M11 current-source p50 0.012 ms, p95 0.018 ms, p99 0.022 ms, max 0.121 ms; 10,000 ordered dispatches. |
| Microphone activation | Warm maximum ≤ 250 ms. | p50 48.118 ms, p95/p99/max 87.050 ms across five starts; one-time preparation 149.539 ms. |
| Local AI semantic safety | No accepted provider output may corrupt protected content; invalid output falls back to Edited text once. | Fixed 17-case corpus plus spoken-edit, replay, Style, structured-block, renderer, controller, and migration tests. |
| Local AI refinement | Warm raw-final-to-refined p95 ≤ 1 s on the reference Mac. | Prompt-5 Qwen 3.5 4B p95 0.908 s. |
| Local AI end to end | Warm release-to-insertion p95 ≤ 1.5 s on the reference Mac. | Prompt-5 prewarmed M4 production-controller p95 1.004 s. |
| Local AI deadline | Preparation plus generation must fall back within three seconds after final speech text. | Deterministic deadline and late-output tests. |
| Voice History | Warm 5,000-session search p95 ≤ 250 ms; startup recovery precedes retention without delaying the input runtime. | M8 current-source p95 2.639 ms; M12 passes 496 Swift tests in 74 suites plus 10 Rust domain/ABI tests and one linked C consumer. |
| Privacy | Voice artifacts remain app-owned and local; no speech content is logged; no remote-capable provider receives a call; Ollama cannot reach a nonloopback endpoint. | Deterministic provider-boundary, SQLite/CAF, fallback, static-scan, and fixed-endpoint transport tests. |
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

The signed M7 packaged UI exposes stable accessibility identifiers for each
retention picker, exact MiB/GiB choices, default and `Unlimited` states, and a
typed storage-size expiration reason while leaving transcript reuse available.
Light, dark, increased-contrast, reduced-motion, and large-text demo modes retain
the complete Voice History storage control and disclosure hierarchy.

The signed M8 packaged UI marks recovered sessions, selects truthful empty Raw
evidence, explains the 24-hour recovery limit, and keeps unavailable reuse
actions disabled. Light, dark, increased-contrast, reduced-motion, and large-
text modes preserve the hierarchy; keyboard-only sidebar navigation and the
combined accessibility stage/source/from description remain synchronized.

The signed M10 packaged menu exposes an enabled **Record Voice** action beside
the connected-Device and active-Profile state. Its native accessibility tree
uses the same label, and the installed app retains Controller readiness after a
verified quit and exact-bundle relaunch.

The signed M12 packaged History UI exposes an enabled **Import Audio Recording**
action with identifier `voice_history_import_audio`, presents the native audio
open panel, and returns to History without mutation when cancelled. The
installed arm64 binary is byte-identical to the verified candidate, has CDHash
`58c6a1aadc20ea8f12983db7ad6efbe676a3cc85`, and carries only the audio-input
entitlement. The replaced M11 app remains recoverable from the private
validation backup until this candidate is superseded.

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
| Local service becomes a remote path | Require typed provider locality, reject remote-capable adapters before invocation, fix Ollama to numeric loopback, disable redirects/proxies, and reject cloud-only model identities. |
| UI or inference delays input | Keep HID decoding and Action dispatch off the main actor and outside speech/model work. |
| Personal artifact is mistaken for a release | Keep install and release promotion explicit and retain private signing evidence outside source control. |
| Modified build is mistaken for official | Keep canonical-project identification explicit and require official Releases to pass the gated notarization workflow. |

Promote a version only when its intended scope has current automated, physical,
accessibility, signing, installation, privacy, and performance evidence and the
user explicitly approves that exact version.
