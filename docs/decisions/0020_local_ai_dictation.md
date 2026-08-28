# 0020: Separate Local AI Dictation Action

- **Status:** Accepted; implemented in current source
- **Date:** 2026-08-17
- **Amends:**
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)
- **Future persistence/provider scope amended by:**
  [`0029_local_voice_platform_expansion.md`](0029_local_voice_platform_expansion.md)

## Context

Local Dictation provides deterministic, app-owned speech recognition and safe
text delivery. A separate workflow should turn the same spoken input into
polished text by removing fillers, resolving clear self-corrections, correcting
supported recognition mistakes, and choosing punctuation, paragraphs, or lists
automatically.

The existing Local Dictation Action must remain behaviorally unchanged. The new
workflow must reuse the proven audio, recognition, target, delivery, permission,
and interaction boundaries rather than copy them. All audio, transcript,
context, prompts, and inference must remain local.

Neither Apple's on-device `SystemLanguageModel` nor Ollama's documented API
accepts audio input. A new audio-language or Whisper runtime would add another
recognizer, model lifecycle, memory footprint, and failure surface without
evidence that it improves this workflow.

## Pipeline decision matrix

| Criterion | Apple speech plus text refinement | Whisper plus text refinement | One audio-language model |
| --- | --- | --- | --- |
| Reuses proven capture and recognition | Yes | Capture only | Capture only |
| Preserves Local Dictation behavior | Yes | Yes | Yes |
| Additional recognition runtime | None | Required | Required |
| Apple and Ollama refinement | Both | Both | Model-specific |
| First increment | Selected | Extension point | Deferred |

## Decision

### Product boundary

- Add **Local AI Dictation** as a distinct Action next to No Action, Local
  Dictation, and Keyboard Shortcut.
- Keep Local Dictation's Action identity, configuration, controller, live
  composition, failure behavior, and defaults unchanged.
- Support Momentary and Toggle modes plus the existing exact keyboard fallback.
- Use a process-wide coordinator so only one microphone-owning Dictation Action
  can run at a time.

### Shared and new responsibilities

- Reuse microphone capture, Apple speech recognition, target capture,
  permission preflight, transcript delivery, recovery, and application
  lifecycle services through narrow protocols.
- Give Local AI Dictation its own orchestration and state, including model
  preparation, refining, validation, and raw fallback.
- Do not merge both workflows into one mode-switched controller and do not
  duplicate the existing transcription controller.
- Preserve a provider seam for a future local speech recognizer or direct-audio
  model if measured evidence justifies one.

### Refinement providers and models

- Ship Apple on-device Foundation Models and Ollama refinement providers in the
  first Local AI Dictation increment.
- Keep provider and model selection machine-wide. Bindings select the Action,
  interaction mode, and keyboard fallback only.
- Treat Apple's system model as OS-managed and availability-gated.
- Connect Ollama only through fixed loopback access. Require a locally installed
  model with a stable digest and reject cloud-only models and remote endpoints.
- Bundle a source-controlled catalog of validated model identities. Select one
  measured model as the default recommendation while allowing installed,
  compatible models to be chosen explicitly as unvalidated.
- Warm the selected model asynchronously after Action begin while the user is
  speaking. Offer finite retention by default and explicit process-lifetime
  retention for lowest latency. Before requesting indefinite retention, inspect
  Ollama's running models. On model change or app shutdown, unload only a model
  this process started; preserve every model already shared by another client.

### Context, prompt, and dictionary

- Supply locale, active Profile, target application identity, target role,
  delivery capabilities, dictionary entries, and optional recognition evidence
  to the refinement provider.
- Allow an explicit setting to supply a bounded window around the caret when a
  nonsecure target exposes it safely. Never read secure fields, terminal
  contents, browser URLs, screenshots, whole documents, or the pasteboard.
- Keep all session context in memory. Never persist or log audio, transcript, or
  target content.
- Build prompts from a non-editable invariant policy, a versioned
  provider-specific template, and optional user instructions. Prompt and model
  changes require evaluation against the same source-controlled corpus.
- Treat transcript and context as untrusted data, not model instructions.
- Store manual vocabulary hints separately from exact spoken-form replacements.
  Feed supported hints to speech recognition and both entry types to refinement.

### Output and failure behavior

- Keep provisional Local AI text in the existing transient HUD. Deliver once
  after recognition finalization, refinement, and validation.
- Tell the provider whether the target safely supports multiline text so list
  and paragraph formatting remain automatic without risking submission.
- Validate nonempty output, length bounds, control characters, and protected
  numbers, URLs, email addresses, paths, code-like tokens, and dictionary terms.
- Bound refinement independently from speech finalization. On provider failure,
  timeout, invalid output, focus change, or cancellation, discard late output
  and preserve or deliver the raw transcript exactly once when still safe.
- Retain raw and refined text only for the current recovery state and expose
  explicit copy recovery.

### Performance and privacy

- Keep the HID callback-to-Action-dispatch contract unchanged.
- Measure model preparation, recognition finalization, refinement, validation,
  and delivery separately with a monotonic clock.
- Report cold and warm p50, p95, p99, maximum, sample count, selected model
  digest, and incremental resident memory.
- Target warm raw-final-to-refined p95 at or below one second and warm
  release-to-insertion p95 at or below 1.5 seconds. Use a three-second
  refinement deadline until measured evidence supports a tighter bound.
- Replace the absolute **No network access** claim when Ollama support ships.
  Loopback HTTP is network activity even though inference remains local. Product
  copy must instead promise local processing and no cloud inference.

### Documentation lifecycle

- Treat Git history as the archive. Canonical docs describe current behavior,
  current constraints, and remaining work rather than narrating completed work.
- Retain accepted and superseded decision records because they explain durable
  choices. Do not create a separate documentation archive.
- Delete completed implementation plans after their lasting behavior and
  constraints are represented in the product brief, architecture, game plan,
  context map, or decision records.
- Retain release evidence only while it validates an intentionally retained
  artifact. Remove rejected and obsolete intermediate reports after their
  durable lessons are captured in decisions or current verification guidance.
- Remove obsolete dates, versions, pause narratives, duplicated histories, and
  stale links from evergreen docs in the implementation change.

## Consequences

- Users explicitly choose between fast live Local Dictation and final-only
  Local AI Dictation.
- Apple and Ollama share one typed refinement contract without sharing provider
  implementation details.
- The first increment gains no second speech-recognition dependency.
- Ollama introduces an optional local external-service dependency and requires
  precise readiness and privacy presentation.
- Model and prompt quality become evaluated product inputs rather than
  unversioned implementation details.

## Implementation evidence

The current source implements the separate Action, process-wide Dictation
coordination, shared speech/target/delivery composition, both local refinement
providers, prompt revisioning, bounded context, dictionary, validation,
three-second fallback, recovery UI, and machine-wide settings. Model selection
and measurements are recorded in
[`0021_local_ai_model_selection.md`](0021_local_ai_model_selection.md) and
[`../local_ai_model_evaluation.md`](../local_ai_model_evaluation.md).

## Sources

- [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels/)
- [Apple Speech `AnalysisContext`](https://developer.apple.com/documentation/speech/analysiscontext)
- [Ollama generate API](https://docs.ollama.com/api/generate)
- [Ollama model loading and retention](https://docs.ollama.com/faq)
- [Ollama Qwen 3.5 model tags](https://ollama.com/library/qwen3.5/tags)
- [WhisperKit](https://github.com/argmaxinc/whisperkit)
