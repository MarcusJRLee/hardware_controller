# Product brief

## Promise

A physical Control feels like a native extension of the Mac: connect it, choose
what it does, and get an immediate, predictable response in the active app.
The primary workflow is hands-free Dictation: put the cursor in a field, hold
the center pedal, speak, release. On iPhone, the Voice Input app and keyboard
bring the same local Voice pipeline to any text field.

## Principles

1. **Immediate:** input and speech latency have explicit percentile budgets.
2. **Quiet:** the app stays out of the way until state or setup needs you.
3. **Legible:** Device, permission, Profile, provider, and Action state are
   obvious.
4. **Safe:** disconnects, permission loss, bad model output, and termination
   never leave an Action held or change the wrong field.
5. **Local:** configuration, speech, context, and generation stay on-device.
6. **Extensible:** hardware facts stop at the Driver; models stop at typed
   provider boundaries.

## Canonical language

| Term | Meaning |
| --- | --- |
| Device | One connected physical controller. |
| Control | One independently actuated input on a Device. Say `pedal` only in Infinity-specific copy. |
| Control event | A timestamped press, release, or value change. |
| Driver | Device-specific adapter that turns raw input into Control events. |
| Action | Behavior the app can execute. |
| Binding | A Control plus interaction mode mapped to an Action. |
| Profile | A named, versioned collection of per-Device Bindings. |
| Momentary | Begin on press, end on release. UI says **Hold**. |
| Toggle | Alternate begin and end on successive presses. |
| Active Action | An Action that began and has not ended. |
| Raw / Edited / Formatted / Delivered | Speech text before edits; after spoken edits and Dictionary; validated paragraph/list blocks; the target-specific rendering. |
| Spoken edit | A typed, source-evidenced command applied before formatting. |
| Style | Versioned Natural, Casual Message, Formal, Technical, or Verbatim policy. |
| Provider locality | Furthest boundary a model adapter can reach: in-process, fixed loopback, or remote-capable. |
| Voice trigger | Any input that begins, finishes, or cancels the same Voice session. |
| Voice chord | The optional machine-wide shortcut for Voice capture; not a Binding fallback. |
| Retained audio | The optional app-owned CAF of one Voice session. |
| Recovery session | A History session rebuilt from interrupted audio, with no invented text. |

## Scope

- **Devices:** one or more VEC Infinity 3 pedals, all three Controls,
  simultaneous presses, reconnect and sleep safety.
- **Actions:** No Action, Local Dictation, Local AI Dictation, Keyboard
  Shortcut, each with Hold and Toggle. One Dictation Action owns the
  microphone at a time.
- **Local AI:** spoken edits, Dictionary, Styles and casing, typed
  paragraph/list output, validation of protected content, and a deterministic
  Edited fallback within three seconds.
- **Configuration:** Profiles with independent per-Device setups; center
  defaults to Local Dictation (Hold), left and right to No Action; opt-in
  keyboard fallbacks and Voice chord, never enabled automatically.
- **History:** searchable, append-only sessions with bounded audio retention
  that never deletes transcripts; correction, retranscription, reformatting,
  explicit re-delivery, archives, and audio import.
- **App:** foreground app with Dock and menu-bar presence; Controller, History,
  Profiles, and General in one window; Launch at Login only on request.
- **iOS:** containing app owns capture, local ASR, formatting, and History; the
  custom keyboard inserts confirmed results; system controls and Shortcuts
  start capture.

## Approved boundaries

| Decision | Approval | Record |
| --- | --- | --- |
| Privacy | On-device speech; Apple On-Device or fixed-loopback Ollama refinement; no cloud inference. | [0020](decisions/0020_local_ai_dictation.md), [0033](decisions/0033_local_only_voice_enforcement.md) |
| Platforms | macOS 15+ on Apple silicon, and iOS. Android, Windows, and Linux stay in line of sight; web is deferred. | [0001](decisions/0001_native_macos_stack.md), [0029](decisions/0029_local_voice_platform_expansion.md) |
| Profiles | Manual multi-Profile UI with per-Device setups. | [0014](decisions/0014_multi_profile_device_configuration.md) |
| Model | Digest-pinned Qwen 3.5 4B recommended; other installed models allowed, labeled unvalidated. | [0021](decisions/0021_local_ai_model_selection.md) |
| Builds | Every change installs as a signed private build; release promotion needs explicit approval. | [0023](decisions/0023_stable_personal_build_metadata.md) |
| Source | Apache 2.0, Marcus John Rice Lee as copyright holder; contributions welcome, no CLA. | [0028](decisions/0028_apache_open_source_and_contributions.md) |
| Workflow | Feature branches from `main`, squash-merged PRs. | [0052](decisions/0052_main_feature_branch_workflow.md) |

## Out of scope

- Accounts, sync, analytics, telemetry, remote control, or remote models
  (including Private Cloud Compute).
- Downloaded Driver code, plug-ins, shell commands, or AppleScript.
- Automatic per-app Profile switching.
- App Store submission, payments, licensing, or update infrastructure.

Changing any of these needs a new decision record.
