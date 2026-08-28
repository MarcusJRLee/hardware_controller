# Decision 0054: Typed Local AI formatting output

**Status:** Accepted

## Context

Prompt revision 5 asked every formatter for one text field. That made paragraph
and list boundaries model-dependent, and text parsing could not reliably infer a
spoken grocery list. Casing-only model changes could also corrupt operational
tokens before deterministic lowercase enforcement.

| Criterion | Typed blocks plus deterministic normalization | Provider text plus parsing | Provider-specific documents |
| --- | --- | --- | --- |
| Paragraph/list boundary | Explicit | Heuristic | Explicit |
| Protected casing | Source-restored | Validation fallback only | Adapter-dependent |
| macOS/iOS semantic parity | Shared Core source | Parser-dependent | Duplicated |
| Evaluation flexibility | Typed invariants plus diagnostic exact score | Exact prose bias | Adapter-specific |
| Decision | Selected | Rejected | Rejected |

## Decision

- Prompt revision 6 returns `VoiceFormattingDraft.blocks`. Each block is a
  paragraph, unordered list, or ordered list with typed items.
- Ollama receives an exact nested JSON schema. Apple Foundation Models receives
  one constrained block envelope; paragraph items expand into independent
  paragraph blocks at the adapter boundary.
- Canonicalize provider paragraph items before building the evidence-backed
  document. Reject empty blocks, unsafe controls, unknown kinds, or invalid
  envelopes.
- When typed list intent has deterministic boundaries, rebuild list blocks from
  Edited text. Support explicit markers, sequential ordinals, and conservatively
  delimited list cues. Preserve provider output when boundaries are uncertain.
- Restore the source spelling of protected operational tokens during lowercase
  transformation, using case-insensitive matching. Validation still rejects
  missing or semantically changed tokens.
- Validate the canonical rendered document before delivery. Provider, schema,
  semantic, or deadline failure delivers deterministic Edited fallback once.
- Keep exact output matching diagnostic. The 19-case semantic gate permits at
  most a 15% semantic-failure rate and 10% provider-error rate, but permits no
  casing, protected-token, or required-structure failure in final candidates.
- Compile and invoke the casing, list-intent, draft-normalization,
  block-builder, and renderer sources in the portable iOS core. Platform model
  adapters may still differ.

## Verification

Focused tests cover JSON schema decoding, Apple envelope adaptation, typed
paragraph/list building, protected-token restoration, grocery/ordinal/explicit
list normalization, History reformatting, controller delivery, and semantic
gate behavior. The opt-in provider corpus records exact quality, typed failure
kinds, latency distributions, errors, throughput, and resident memory.

## Implications

Model output no longer owns list inference or lowercase safety. A larger model
can improve prose, but it cannot replace deterministic semantics, canonical
validation, or fallback. This decision does not change the ASR provider or
supersede the existing Ollama recommendation.
Settings therefore name ASR and formatting evidence separately, while History
shows the stored validation result and deterministic fallback use.
