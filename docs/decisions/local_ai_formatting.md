# Local AI Dictation and formatting

- **Status:** Accepted
- **Updated:** 2026-11-06
- **Replaces:** 0020, 0021, 0053, 0054, 0058

## Context

Local AI Dictation turns speech into polished text: fillers removed, clear
self-corrections applied, punctuation, paragraphs, and lists chosen. Plain
Local Dictation must stay unchanged. Formatting models are untrusted, slow
sometimes, and inconsistent about casing and list boundaries, so the semantics
cannot live in a prompt.

| Criterion                    | Typed blocks + deterministic rules | Provider text + parsing | Prompt-only instructions |
| ---------------------------- | ---------------------------------- | ----------------------- | ------------------------ |
| Paragraph and list boundaries| 🟢 Explicit.                       | 🟠 Heuristic.           | 🔴 Model-dependent. |
| Protected tokens and casing  | 🟢 Restored from source.           | 🟡 Validation only.     | 🔴 Best effort. |
| macOS/iOS parity             | 🟢 Shared Core source.             | 🟡 Parser-dependent.    | 🔴 Needs equal models. |

| Ollama model    | Exact outputs | Validator rejections | Warm p95 | Resident memory |
| --------------- | ------------- | -------------------- | -------- | --------------- |
| Qwen 3.5 4B     | 9/17          | 0                    | 0.935 s  | 5.74 GB |
| Qwen 3.5 9B     | 11/17         | 1                    | 1.294 s  | 8.52 GB |
| Apple On-Device | 8/17          | 2                    | 1.600 s  | OS-managed |

Recognizers return "P R forty-four" for "PR 44". Five fixes were compared:

| Criterion | Literal entry per number | Recognition hint | Prompt rule | Convert every number | `{number}` slot |
| --- | --- | --- | --- | --- | --- |
| Any number, not just one | 🔴 One entry each. | 🔴 | 🟡 Model-dependent. | 🟢 | 🟢 |
| Engines and Verbatim | 🟢 | 🟠 Parakeet ignores hints. | 🔴 Skipped by Verbatim. | 🟢 | 🟢 |
| Deterministic and testable | 🟢 | 🔴 | 🔴 | 🟢 | 🟢 |
| Leaves other prose alone | 🟢 | 🟢 | 🟠 | 🔴 "two kids" → "2 kids". | 🟢 Only beside its words. |

## Decision

**Product boundary**

- **Local AI Dictation** is a distinct Action beside No Action, Local
  Dictation, and Keyboard Shortcut. It supports Momentary, Toggle, and the
  keyboard fallback, and shares capture, ASR, targeting, delivery, recovery, and
  lifecycle through narrow protocols with its own orchestration.
- Provider and model are machine-wide. Bindings choose only the Action, mode,
  and fallback chord.

**Providers**

- Apple Foundation Models (in-process, availability-gated) and Ollama on fixed
  loopback `127.0.0.1:11434` only, with a locally installed, digest-pinned model.
  Reject cloud models and remote endpoints ([local_only_boundary](local_only_boundary.md)).
- Recommend `qwen3.5:4b` at digest
  `2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd`, labeled
  recommended only on an exact digest match. Other installed models are
  selectable once pinned, never labeled validated. Disclose that 5.74 GB exceeds
  the 4 GB target.
- Warm the model while the user speaks. Default Ollama retention is five
  minutes; process-lifetime retention is an explicit choice. Unload only models
  this process loaded.

**Context and prompt**

- Supply locale, Profile, target app and role, delivery capabilities,
  Dictionary entries, and recognition evidence. A setting may add a bounded
  window around the caret in a non-secure target; never read secure fields,
  terminal contents, URLs, screenshots, whole documents, or the pasteboard.
- Prompts are an invariant policy, a versioned provider template, and optional
  user instructions. Transcript and context are untrusted data. Any prompt,
  validator, context, or model change re-runs the fixed corpus.

**Styles, casing, and lists**

- Styles: Natural, Casual Message, Formal, Technical, Verbatim. Verbatim skips
  the model.
- Casing: Style Default, Lowercase Prose, or Strict Lowercase, applied after
  polishing to provider and fallback output alike. Both lowercase policies keep
  URLs, emails, paths, code identifiers, quotes, and Dictionary values; Lowercase
  Prose also keeps signaled names and acronyms.
- Each request carries typed list intent: ordered from numeric markers or
  sequential ordinals, unordered from bullets or a list cue with conservative
  delimiters. Never guess boundaries from undelimited words. Spoken commands
  include `start a bullet list`, `bullet`, and `next item` (spoken-edit
  revision 2; revision 1 still replays).
- Prompt revision 6 returns `VoiceFormattingDraft.blocks`: paragraphs, unordered
  lists, or ordered lists. Ollama gets an exact JSON schema; Apple gets one
  constrained envelope. When list intent has deterministic boundaries, rebuild
  lists from Edited text.

**Output and failure**

- Deliver once, after recognition, formatting, and validation. Validate
  nonempty output, length, controls, and protected numbers, URLs, emails,
  paths, code tokens, and Dictionary terms on the rendered document.
- Formatting has its own three-second deadline. Provider, schema, semantic,
  deadline, or focus failure delivers deterministic Edited text once, if still
  safe; late output is discarded. Raw and refined text stay available for copy.
- The 19-case semantic gate allows at most 15% semantic and 10% provider
  failures and zero casing, protected-token, or structure failures.

**Dictionary**

- Recognition hints and spoken-form replacements are stored separately.
  Hints reach Apple speech and transcribe.cpp models that support them.
- Replacements run in Core (`PersonalDictionaryReplacementApplier`) before the
  model, case- and word-boundary-aware, longest spoken form first. An all-caps
  word or a run of single letters also matches spaced or dotted letters, so
  `PR` matches "P R" and "P.R.".
- A spoken form may hold one `{number}` slot beside at least one word. English
  cardinals, digit-by-digit runs, and numerals become digits in every
  `{number}` of the replacement; trailing non-number words stay. Spelled
  numbers elsewhere are never converted, because bare digits change prose
  ("two kids"). Invalid slot patterns are refused on save and never applied.
  Casing and validation protect the rendered text (`PR 44`), not the template.
  Number words are English only; other locales need their own grammar.
- After **Save Correction**, suggest up to three entries from word-level
  substitutions of one to four words that look like a name or term. A rewrite
  (over three spans or 40% of words) suggests nothing. Offer a replacement only
  when several spoken words became one term. Nothing is saved without **Add**.

**Measurement**

- Measure preparation, finalization, formatting, validation, and delivery
  separately on a monotonic clock, cold and warm, with digest and memory.
  Targets: warm raw-to-formatted p95 ≤ 1 s and warm release-to-insertion
  p95 ≤ 1.5 s. Qwen 3.5 4B measured release-to-insertion p50 0.838 s and
  p95/p99/max 1.052 s (17 samples).

## Consequences

- Users choose between fast live Local Dictation and final-only Local AI
  Dictation.
- A better model can improve prose but cannot replace list rules, casing
  safety, validation, or fallback.
- Product copy promises local processing and no cloud inference rather than
  "no network": Ollama uses loopback HTTP.
- Method and reproduction: [`../local_ai_model_evaluation.md`](../local_ai_model_evaluation.md).
  Lower-tier Apple silicon performance remains a physical evidence gate.
