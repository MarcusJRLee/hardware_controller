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
The migration was completed on 2026-08-21:

| Decision | Current approval |
| --- | --- |
| Source license | PolyForm Noncommercial 1.0.0 with the tracked Marcus John Rice Lee notice. |
| Copyright holder | Marcus John Rice Lee. |
| Future entity | Longdevity LLC formation and signed ownership transfer are future work, not publication gates. |
| Contributions | Accept issues; pause external code until separate contributor terms are approved. |
| Public history | Published at the same URL from one sanitized noreply-authored root commit; retained private history only in an external private archive. |
| Product icon | Use Signal Bridge provisionally and iterate later through a superseding decision. |
| GitHub controls | Verified branch rules, read-only Actions permissions, secret scanning, push protection, dependency alerts, CodeQL, and private vulnerability reporting on the replacement repository. |

The public repository gate was satisfied on 2026-08-21. Public source approval
does not approve a signed binary, DMG, tag, or GitHub Release.
