# 0061: Bundle the iOS starter speech model

- **Status:** Accepted
- **Date:** 2026-11-02
- **Amends:** [0041](0041_ios_model_package_admission.md)

## Context

A fresh Voice Input install could not dictate. The only model path was to run
`scripts/prepare_ios_asr_model_package.sh` on a Mac, copy the folder into
Files, then import and select it. The owner's own device never got past
"Failed". The app may not download models (no network entitlement).

## Decision matrix

| Criterion | Bundle and admit on first launch | Mac-prepared Files import only | Load straight from the app bundle |
| --- | --- | --- | --- |
| Works on first launch | 🟢 Yes. | 🔴 Needs a Mac and three manual steps. | 🟢 Yes. |
| Keeps one admission path (0041) | 🟢 Same Rust validator and installer. | 🟢 Same. | 🔴 Second, unvalidated runtime path. |
| Provenance | 🟢 Pinned manifest digest; shown **Verified**. | 🟠 **Manual import**. | 🟡 Code signature only. |
| App size | 🟠 +45 MB (Whisper Tiny + Silero VAD). | 🟢 None. | 🟠 +45 MB. |
| Storage | 🟠 Bundle copy plus private copy. | 🟢 One copy. | 🟢 One copy. |

## Decision

`scripts/generate_ios_project.sh` regenerates the starter package from the
digest-pinned assets on every generation, and the app bundles it as
`starter_asr_model`. On the first Model-library refresh of each launch, when no
speech model is selected and the library holds no compatible package, the app
installs the starter through the normal installer with its manifest SHA-256
pinned in `VoiceInputStarterModel`, then selects it. An invalid saved selection
still surfaces as an error. A model the user installed always wins; removing
the starter lasts until a later launch finds no compatible model.

Imported Model packages remain supported for larger or other models.

## Consequences

- Dictation works on a fresh install with no Mac-side step.
- A unit test fails if the bundled manifest drifts from the pinned digest; the
  installer refuses drifted bytes at runtime.
- History stores audio by file name under the current container, because iOS
  can move the container between installs and updates.
