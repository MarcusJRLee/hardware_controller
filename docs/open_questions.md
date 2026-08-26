# Product approval gate

Gate 0 is closed. The current approved boundaries are:

| Decision | Current approval | Authority |
| --- | --- | --- |
| Dictation privacy | Apple speech recognition is on-device. Local AI refinement uses Apple On-Device or fixed-loopback Ollama with ephemeral content and no cloud inference. | [`0020_local_ai_dictation.md`](decisions/0020_local_ai_dictation.md) |
| Default interaction | Center defaults to Hold; Toggle remains configurable. | [`product_brief.md`](product_brief.md#canonical-language) |
| macOS support | Target macOS 15 and later on Apple silicon. Apple Foundation Models require macOS 26; Ollama remains independently selectable. | [`0001_native_macos_stack.md`](decisions/0001_native_macos_stack.md) |
| Distribution | Install every change as a signed private build without automatic metadata changes; release promotion remains separately gated. | [`0023_stable_personal_build_metadata.md`](decisions/0023_stable_personal_build_metadata.md) |
| Launch behavior | Enable Launch at Login only after explicit user action. | [`product_brief.md`](product_brief.md#app-experience) |
| Profile scope | Manual multi-Profile UI with independent per-Device setups. | [`0014_multi_profile_device_configuration.md`](decisions/0014_multi_profile_device_configuration.md) |
| Local AI model | Recommend the measured digest-pinned Qwen 3.5 4B; allow explicitly selected installed models as unvalidated. | [`0021_local_ai_model_selection.md`](decisions/0021_local_ai_model_selection.md) |

Left and right Controls default to No Action but remain independently
configurable. Shell commands, AppleScript, accounts, analytics, telemetry,
cloud storage, remote inference, and general network features remain outside
the approved scope.

Future changes require a new or superseding decision record. No unresolved
question currently blocks product code.

## Public repository

Publication decisions are accepted in
[`0025_public_source_publication.md`](decisions/0025_public_source_publication.md)
and amended by
[`0027_individual_publication_ownership.md`](decisions/0027_individual_publication_ownership.md).
Licensing and contributions are superseded by
[`0028_apache_open_source_and_contributions.md`](decisions/0028_apache_open_source_and_contributions.md).
The migration was completed on 2026-08-21:

| Decision | Current approval |
| --- | --- |
| Source license | Apache License 2.0 with the tracked Marcus John Rice Lee notice. |
| Copyright holder | Marcus John Rice Lee. |
| Future entity | Longdevity LLC formation and signed ownership transfer are future work, not publication gates. |
| Contributions | Welcome issues and pull requests under Apache 2.0 Section 5; contributors retain copyright and no CLA is required. |
| Public history | Published at the same URL from one sanitized noreply-authored root commit; retained private history only in an external private archive. |
| Product icon | Use Signal Bridge provisionally and iterate later through a superseding decision. |
| GitHub controls | Verified branch rules, read-only Actions permissions, secret scanning, push protection, dependency alerts, CodeQL, and private vulnerability reporting on the replacement repository. |

The public repository gate was satisfied on 2026-08-21. Public source approval
does not approve a signed binary, DMG, tag, or GitHub Release.

## Voice platform expansion gate

The gate closed on 2026-08-25 through
[`0029_local_voice_platform_expansion.md`](decisions/0029_local_voice_platform_expansion.md).
Current behavior remains unchanged until the accepted roadmap ships.

| Decision | Accepted direction |
| --- | --- |
| Product boundary | Add Voice to the existing Hardware Controller macOS app; create no second macOS product. |
| Repository | Use one repository with incremental `apps/`, Rust crate, Apple support, schema, and CUJ boundaries. |
| Delivery | Start with M1 and proceed CUJ-by-CUJ through focused worktree PRs into `dev`; keep `main` gated on final user verification. |
| History | Retain transcripts until deletion; cap successful audio by accepted age, byte, and artifact-count defaults; retain recoverable partials for 24 hours. |
| Local-only | Permit explicit verified Model-package downloads containing no Voice data; exclude Voice data from app sync/backup where supported; add no accounts, telemetry, cloud inference, or remote storage. |
| Models | Use separate ASR and optional formatting stages with deterministic edits, validation, and Raw/Edited fallback; delegate provider/package choice to measured evidence. |
| iOS | Ship a containing app and full custom keyboard; the app owns capture/inference/History and the keyboard controls and inserts confirmed results. |
| Portability | Own portable behavior in Rust, allow measured native kernels behind it, and keep Android/Windows/Linux in line of sight. Defer web/mobile web. |
| Deployment floors | Preserve macOS 15 for the spike and choose iOS/lowest-device support from benchmarks. |

No unresolved user choice blocks the implementation goal. K0 signed-device,
model, performance, and App Review checks are evidence gates that must not stop
independent work. Release promotion and `dev` → `main` remain separately gated.
