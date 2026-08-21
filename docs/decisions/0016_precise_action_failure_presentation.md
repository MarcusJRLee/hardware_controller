# 0016: Precise Action failure presentation

- **Status:** Accepted
- **Date:** 2026-08-03

## Context

A Local Dictation begin command can be accepted by the serialized dispatcher
and then fail target, permission, audio, model, recognition, or insertion work.
The runtime reconciled Action ownership correctly, but also rewrote the
accepted dispatch result to `false`. Controller then inserted a generic
"Action could not start" card above the Device while the typed transcription
card already showed the exact failure. The duplicate card was inaccurate and
caused the page to jump when a control was pressed without an editable target.

## Decision matrix

| Criterion | Keep both cards | Hide every generic failure | Preserve dispatch semantics |
| --- | ---: | ---: | ---: |
| Accurate failure source | 1 | 3 | 5 |
| Keeps executor rejection visible | 5 | 1 | 5 |
| Avoids duplicate reflow | 1 | 5 | 5 |
| Preserves Action cleanup | 5 | 5 | 5 |
| **Total** | **12** | **14** | **20** |

## Decision

- Keep `lastActionDispatchSucceeded` limited to the synchronous executor
  acceptance boundary.
- Let asynchronous failure reconcile Momentary or Toggle ownership without
  rewriting an accepted dispatch result.
- Use the typed `TranscriptionSnapshot.failure` card as the sole presentation
  for Local Dictation failures.
- Reserve the generic Action card and status pill for an executor that rejects
  dispatch immediately.
- Keep the Device stage's fixed layout and visual press animation unchanged.

## Consequences

- Missing editable focus still fails closed before microphone capture.
- Controller shows one precise recovery message and no longer inserts a
  duplicate card after the pedal press.
- Toggle ownership still resets after asynchronous failure, so the next press
  can begin normally.
