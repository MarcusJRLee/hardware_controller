# Decision 0053: Voice casing and spoken-list semantics

**Status:** Accepted

## Context

Natural Style capitalization and deterministic polishing could override a
lowercase formatting instruction. A provider returned one text field, so it
could not reliably distinguish paragraphs from spoken grocery-list items.
macOS and iOS also needed one semantic contract before their model adapters
converge.

| Criterion | Typed deterministic policy | Prompt-only instruction | Platform-specific rules |
| --- | --- | --- | --- |
| Provider and fallback agreement | Exact | Model-dependent | Adapter-dependent |
| Protected operational tokens | Explicit | Best effort | Drift-prone |
| macOS/iOS parity | Shared source | Requires equal models | Duplicated |
| Stored spoken-edit compatibility | Revisioned | Not applicable | Duplicated |
| Decision | Selected | Rejected | Rejected |

## Decision

- Model casing as Style Default, Lowercase Prose, or Strict Lowercase. An
  explicit policy overrides Style capitalization. The legacy instruction
  “only provide text in lowercase” normalizes to Strict Lowercase.
- Apply casing after deterministic polishing on accepted provider output and to
  fallback output. Reformatting History and iOS deterministic formatting use
  the same transformer.
- Preserve URLs, email addresses, paths, code identifiers, quoted phrases, and
  Dictionary values under both lowercase policies. Lowercase Prose also
  preserves source-signaled names and acronyms; Strict Lowercase does not.
- Keep privacy, fidelity, protected-content, and data-handling invariants above
  user formatting preferences. A casing preference cannot authorize semantic
  additions or protected-token mutation.
- Carry typed list intent on each refinement request. Infer ordered intent from
  explicit numeric markers or sequential ordinals. Infer unordered intent from
  explicit bullet markers or a list cue with conservative delimiters. Do not
  guess boundaries from an undelimited word sequence.
- Add exact unordered-list and item-boundary commands in spoken-edit revision 2:
  `start a bullet list`, `start a bulleted list`, `bullet`, and `next item`.
  Retain revision-1 replay with its original command vocabulary.
- Compile casing, list intent, and spoken-edit sources into the portable iOS
  core. Platform ASR and generative formatting may differ; these semantics do
  not.
- Store casing in application-preference schema 7. Schema 6 defaults to Style
  Default, preserving existing output behavior. Older apps reject schema 7
  rather than silently erasing the policy.

## Verification

Focused tests cover policy normalization, protected tokens, provider and
fallback delivery, History reformatting, schema migration, conservative list
intent, explicit unordered-list commands, ordinary noun ambiguity, replay, and
revision-1 compatibility. The iOS simulator runs the same transformer after
spoken edits.

## Implications

Prompt wording is no longer the only enforcement point for casing. Formatting
providers can use list intent to emit typed blocks, while deterministic
fallback remains conservative. ASR model selection remains a separate platform
adapter decision.
