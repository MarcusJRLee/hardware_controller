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
| Voice M13 Model-package admission | Portable Rust verifies bounded V1 manifests, license evidence, canonical inventory, exact bytes, per-file SHA-256, and optional catalog-pinned manifest SHA-256 through the C ABI. | [`decisions/0037_portable_model_package_validation.md`](decisions/0037_portable_model_package_validation.md) |
| Voice M14 portable archive | History exports and restores bounded V1 session evidence through one Swift/Rust/schema/C contract; identical imports are idempotent, conflicts fail closed, and revision 4 migrates. | [`decisions/0038_portable_voice_history_archives.md`](decisions/0038_portable_voice_history_archives.md) |
| Voice M15 Apple adapter | The optimized Rust validators are statically linked behind typed Swift values; production V1 import invokes Rust against its private snapshot before Swift restore. | [`decisions/0039_linked_apple_voice_adapter.md`](decisions/0039_linked_apple_voice_adapter.md) |
| iOS Gate K0 | A signed iOS app, full keyboard, and Control Center extension prove app-owned local capture, bounded same-team Keychain handoff, Live Activity ownership, honest cold activation, and one-time insertion. | [`decisions/0040_ios_keyboard_activation_and_handoff.md`](decisions/0040_ios_keyboard_activation_and_handoff.md) |
| iOS I1 onboarding and Model admission | The production app explains local-only behavior, guides permission and keyboard setup, confirms Full Access handoff, and atomically imports bounded Model packages through the linked Rust validator without network code. | [`voice_cujs.md`](voice_cujs.md#i1--onboard-locally) |
| iOS I2 local finalization and History | The containing app runs real file ASR, shared deterministic spoken edits and semantic formatting, then durably stores searchable/playable Raw, Edited, Formatted, model, timing, digest, and bounded-audio evidence before publishing text. | [`decisions/0043_ios_local_formatting_and_history.md`](decisions/0043_ios_local_formatting_and_history.md) |
| iOS I2/I6 Style-qualified delivery | App and keyboard defaults remain separate; an exact schema-V2 stop carries one Style into commit-before-publish formatting, and insertion deduplicates by session identity. | [`decisions/0044_ios_style_qualified_keyboard_delivery.md`](decisions/0044_ios_style_qualified_keyboard_delivery.md) |
| iOS I5/I9 target-safe delivery | Voice is disabled for constrained, sensitive, or unverified traits while QWERTY remains available; one ephemeral session/document/revision tuple gates delivery and target changes recover through History. | [`decisions/0045_ios_host_field_and_delivery_target_safety.md`](decisions/0045_ios_host_field_and_delivery_target_safety.md) |
| iOS I7 lifecycle recovery | Live Activity ownership gates background recording; typed interruption, route, power, thermal, and background-finalization decisions preserve exact partial audio in 24-hour Recovery History without automatic resume. | [`decisions/0046_ios_capture_lifecycle_and_recovery.md`](decisions/0046_ios_capture_lifecycle_and_recovery.md) |
| iOS I8 stale-service recovery | Recording and Transcribing publish bounded heartbeats; stale or replayed state stops keyboard polling, exposes one honest restart path, and cannot revive completed delivery. | [`decisions/0047_ios_stale_service_recovery.md`](decisions/0047_ios_stale_service_recovery.md) |
| iOS I9 insertion recovery | One automatic attempt may expose one explicit same-process retry and local-only expiring copy only while the exact claimed result and target remain unchanged; every ambiguity falls back to History. | [`decisions/0048_ios_bounded_insertion_recovery.md`](decisions/0048_ios_bounded_insertion_recovery.md) |
| iOS I10 offline storage | Versioned local presets enforce age/byte/count and 1-GiB-reserve cleanup, persisted pinning protects selected audio, maintenance never invalidates a durable capture, and Model limits never evict implicitly. | [`decisions/0049_ios_offline_storage_enforcement.md`](decisions/0049_ios_offline_storage_enforcement.md) |
| iOS I11 system capture | A stateful system control, Siri/App Shortcuts, and Live Activity stop finish exact app-owned sessions into History; relaunch ends orphan ownership without deleting partial audio. | [`decisions/0050_ios_system_surface_capture.md`](decisions/0050_ios_system_surface_capture.md) |
| Model recommendation | Qwen 3.5 4B is digest-pinned from the fixed evaluation corpus. | [`decisions/0021_local_ai_model_selection.md`](decisions/0021_local_ai_model_selection.md) |
| Profiles | Transactional named Profiles with independent per-Device setups and active-Action cleanup. | [`decisions/0014_multi_profile_device_configuration.md`](decisions/0014_multi_profile_device_configuration.md) |
| Application | Controller, History, Profiles, and General in one native foreground window with Dock and menu-bar presence. | [`ux_spec.md`](ux_spec.md) |
| Release | Version 1.5.0 build 18 is the approved unreleased personal QA candidate; no release promotion is authorized. | [`decisions/0051_unreleased_voice_integration_build.md`](decisions/0051_unreleased_voice_integration_build.md) |
| Public source | Open source under Apache License 2.0 with Marcus John Rice Lee as copyright owner, inbound Apache contributions, provisional Signal Bridge identity, and active GitHub security controls. | [`decisions/0028_apache_open_source_and_contributions.md`](decisions/0028_apache_open_source_and_contributions.md) |

## Approved next program

The local Voice expansion is accepted and integrated into `dev`: macOS M1–M15,
iOS Gate K0, I1 local onboarding and Model admission, I2 local formatting and
History, Style-qualified keyboard delivery, target-safe field handling, I7
lifecycle recovery, I8 stale-service recovery, I9 bounded insertion recovery,
I10 offline storage, and I11 system-surface capture. macOS and iOS are the
active roadmap; Android, Windows, and Linux remain architectural line-of-sight
platforms; web and mobile web are deferred.
The acceptance and execution authorities are:

| Authority | Purpose |
| --- | --- |
| [`decisions/0029_local_voice_platform_expansion.md`](decisions/0029_local_voice_platform_expansion.md) | Durable product, platform, portability, retention, and delivery choices. |
| [`voice_cujs.md`](voice_cujs.md) | CUJ-first behavioral and testing contract. |
| [`voice_platform_design.md`](voice_platform_design.md) | Model, runtime, iOS keyboard, storage, performance, and milestone design. |
| [`voice_implementation_goal_prompt.md`](voice_implementation_goal_prompt.md) | Autonomous worktree/PR execution contract and definition of done. |

Focused vertical PRs are integrated into `dev`. `main`, tags, distribution
artifacts, and store submission remain unchanged until the user verifies the
finished `dev` state and separately approves promotion.

## Quality gates

| Gate | Contract | Current automated evidence |
| --- | --- | --- |
| HID dispatch | p50 ≤ 3 ms, p95 ≤ 8 ms, p99 ≤ 15 ms, max ≤ 30 ms across 10,000 transitions; no loss or duplication. | M15 current-source p50 0.011 ms, p95 0.017 ms, p99 0.028 ms, max 0.131 ms; 10,000 ordered dispatches. |
| Microphone activation | Warm maximum ≤ 250 ms. | p50 48.118 ms, p95/p99/max 87.050 ms across five starts; one-time preparation 149.539 ms. |
| Local AI semantic safety | No accepted provider output may corrupt protected content; invalid output falls back to Edited text once. | Fixed 17-case corpus plus spoken-edit, replay, Style, structured-block, renderer, controller, and migration tests. |
| Local AI refinement | Warm raw-final-to-refined p95 ≤ 1 s on the reference Mac. | Prompt-5 Qwen 3.5 4B p95 0.908 s. |
| Local AI end to end | Warm release-to-insertion p95 ≤ 1.5 s on the reference Mac. | Prompt-5 prewarmed M4 production-controller p95 1.004 s. |
| Local AI deadline | Preparation plus generation must fall back within three seconds after final speech text. | Deterministic deadline and late-output tests. |
| Voice History | Warm 5,000-session search p95 ≤ 250 ms; startup recovery precedes retention without delaying the input runtime. | M8 current-source p95 2.639 ms; current source passes 513 Swift tests in 76 suites plus 34 Rust domain/archive/model/ABI tests and two linked/native C consumers. |
| Privacy | Voice artifacts remain app-owned and local; no speech content is logged; no remote-capable provider receives a call; Ollama cannot reach a nonloopback endpoint. | Deterministic provider-boundary, SQLite/CAF, fallback, fixed-endpoint transport tests, and an iOS source/capability network scan. |
| iOS local ASR | File-ASR RTF ≤ 0.75 on the pinned native integration corpus; selected bytes are revalidated immediately before load. | `HC_RUN_IOS_ASR_PERFORMANCE=1` enforces the named-hardware gate; whisper.cpp `b4938` + `tiny.en` reference warm CPU RTF 0.0111. Every check runs real transcription correctness; Rust digest/runtime/capability/tamper and timed C/Swift result tests pass. |
| iOS local History | Final output is unavailable until Raw/Edited/Formatted plus audio evidence commit; configurable 90-day/1-GiB/2,000-artifact defaults retain transcripts after audio expiry. | Real SQLite/filesystem tests cover reload, search, digest evidence, migration, pinning, recovery protection, age/count/byte/low-disk expiry, post-commit maintenance failure, Data Protection where exposed, backup exclusion, partial cleanup, and orphan cleanup. |
| iOS keyboard delivery | One exact session and Style stop command produces one automatic attempt; only one explicit same-process retry is available after an unconfirmed result, and stale or malformed state cannot revive delivery. | Stable-Style, exhaustive-mapping, schema-migration, durable-Keychain-claim, exact recovery-policy, real-Keychain warm-journey, re-published-ready, and app-stop tests. |
| iOS stale service | A killed, suspended, or upgraded capture service becomes non-active within three seconds and cannot leave an unbounded wait or revive delivery. | Active-phase heartbeat expiry, future/missing/unknown-schema state, strictly newer result sequence, same-session receipt dominance, and blocked-finalization actor tests. Physical kill/suspension/upgrade evidence remains open. |
| iOS system capture | Control Center, Lock Screen, Action button, Siri, Shortcuts, and Live Activity actions preserve one containing-app owner and finish to History without target inference. | Pure command/state tests, actor ownership reconciliation, generated App Intents metadata inspection, simulator UI, and signed generic-device build. Physical system-surface evidence remains open. |
| iOS field safety | Unsupported traits never read capture state or receive Voice; a late result cannot cross document or session identity. | Normalized-trait, UIKit-mapping, unknown-custom-field, unsupported-policy, and exact-target tests. |
| iOS insertion recovery | An ambiguous host result never triggers an automatic replay; explicit retry/copy require the exact Ready result, receipt, field, and process-local target. | One-retry exhaustion, mismatch, untrusted-schema/phase, UTF-8 copy limit, and ten-minute expiry run in the full simulator suite. Physical host rejection/callback evidence remains open. |
| iOS lifecycle recovery | Capture ownership and system indication agree; interruptions never resume implicitly; a failed finalization preserves exact local audio without blocking History. | Pure lifecycle/notification tests, actor-owned interruption and background-expiration tests, and real SQLite/filesystem exact-artifact reconciliation, migration, isolation, and 24-hour expiry tests. Physical system-event evidence remains open. |
| Documentation | Canonical docs describe current behavior and all links resolve. | All local links resolve. |

Reference Local AI measurements and reproduction commands are in
[`local_ai_model_evaluation.md`](local_ai_model_evaluation.md). Results from a
high-end reference Mac do not establish lower-tier support.

The canonical `/Applications/Hardware Controller.app` contains current-source
version 1.5.0 build 18 under `com.longdevity.hardwarecontroller`, signed by the
private Apple Development Team configured in `.env.local`. Its installed
binary is byte-identical to the verified candidate and passed strict signature,
version, Team, and launch checks. In normal mode it runs from the canonical
path, matches the connected VEC USB Footpedal, reports both Dictation paths
ready, and preserves the accepted Profile. The physical Control has not been
actuated against build 18.

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
M12 validation binary was byte-identical to its verified candidate, had CDHash
`58c6a1aadc20ea8f12983db7ad6efbe676a3cc85`, and carried only the audio-input
entitlement.

The signed M13 canonical app preserves version 1.4.1 build 17 and the M12 macOS
behavior while the portable verifier remains deliberately unlinked. Its arm64
binary is byte-identical to the verified candidate with SHA-256
`ab1384892b300a7c3be86b0cf4b0653dce131e5979ce1fdb5814172afbaf3e62` and CDHash
`c627772b69856cd66c42e42fd229761a5e734ddd`. Strict signature verification,
Team `J4NB9RR32B`, hardened runtime, and the audio-input-only entitlement pass;
the exact Applications bundle launches with connected-Device, active-Profile,
and both Dictation readiness states intact.

The signed M14 canonical app preserves version 1.4.1 build 17 and carries the
native **Import** menu with distinct **Audio Recording…** and **Voice History
Archive…** actions. The archive action presents the native directory picker and
cancel returns to unchanged History. The installed arm64 executable is byte-
identical to the verified candidate with SHA-256
`8be26fa6a671c283a0fcb4e0292cb5304590d63c4e28979ed2f03df1f5bb29b7` and
CDHash `303b9fd09a25f0b191367b82269352b6a1431f15`. Strict signature, Team
`J4NB9RR32B`, hardened runtime, audio-input-only entitlement, Apple/system-only
dependencies, connected Device, active Profile, and both Dictation readiness
states pass. At M14, the Rust archive verifier remained deliberately outside
the Swift app binary pending the shared Apple wrapper.

The signed current canonical app uses version 1.5.0 build 18 and statically
contains `voice_history_archive_validate_v1` and the active
`voice_model_package_validate_v2`; the portable library retains the frozen V1
Model output for binary compatibility. The installed arm64 executable is byte-
identical to the verified candidate. Strict signature, private Team match,
hardened runtime, audio-input-only entitlement, and Apple/system-only dynamic
dependencies pass. The exact Applications bundle launches with the connected
Device, active Profile, and both Dictation readiness states. Signature-dependent
hashes belong to handoff evidence rather than source-controlled current state.

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
