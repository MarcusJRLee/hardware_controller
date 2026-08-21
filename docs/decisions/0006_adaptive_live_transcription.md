# 0006: Adaptive live transcription

- **Status:** Accepted; passive presentation and terminal delivery amended by
  [`0007`](0007_quiet_terminal_delivery.md)
- **Date:** 2026-07-26
- **Amends:** The finalized-only text-delivery rule in
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)

## Context

The app-owned transcriber already publishes provisional recognition in
Hardware Controller, but it inserts only finalized segments into the focused
field. A long utterance can therefore appear live in Settings while its target
remains empty until the user pauses or ends the session.

Inserting every provisional result is not safe. Recognition revises earlier
words, and appending each result would duplicate text. Replacing provisional
text requires the app to prove that the same target and insertion range still
belong to the active session. Terminal emulators and custom editors expose
different Accessibility text capabilities, so one delivery mechanism cannot
be assumed safe everywhere.

The user also needs transcription state at the working cursor instead of only
inside Hardware Controller.

## Delivery decision matrix

| Target capability | Live field behavior | Fallback behavior | Safety |
| --- | --- | --- | --- |
| Settable selected text plus a stable readable and settable selection range | Replace only the session-owned provisional span, then commit final text. | Cursor transcript remains available. | Preferred. |
| Settable selected text without a stable selection range | Do not revise field content. | Show provisional text beside the cursor and insert final text. | Safe compatibility path. |
| Secure, unfocused, or noneditable target | Do not insert. | Show a blocked state and retain recoverable final text. | Fail closed. |
| Synthetic typing and deletion | Not automatic. | Consider only as an explicit, terminal-specific future adapter after physical validation. | Rejected as a generic fallback. |

## Decision

Use capability-adaptive live transcription:

- Normalize both Apple recognition backends into one cumulative revision
  contract containing committed and provisional text. Backend-specific result
  shapes must not leak into composition behavior.
- Capture a focused-target composition lease when Dictation begins. The lease
  records element identity, process identity, insertion range, and supported
  Accessibility operations without reading the field value.
- Use live field composition only when the initial selection is empty and the
  target exposes a readable and settable selected-text range. Before every
  replacement, verify the same element and expected caret. Select and replace
  only the previously inserted provisional span.
- Commit finalized text in place. On safe cancellation, remove the owned
  provisional span. If focus or caret ownership changes, stop automatic
  mutation and preserve recoverable text.
- Keep finalized-only selected-text insertion for targets that cannot prove
  range ownership. Never use the pasteboard or synthetic backspaces
  automatically.
- Present transcription state through a click-through, nonactivating overlay.
  Anchor it beside the text caret when Accessibility provides range bounds and
  beside the pointer otherwise.
- Use shape and text as well as color for Ready, Preparing, Listening,
  Finalizing, Completed, and Blocked states. Respect Reduce Motion and Increase
  Contrast.
- Keep all recognition, composition, target metadata, and transcript text
  local and in memory. Do not read target contents, persist transcripts, log
  transcript text, or add a network entitlement.

## Consequences

- Compatible editors show recognized words while the user speaks and revise
  only text owned by the active session.
- Custom editors and terminals remain useful through a live cursor transcript
  and final insertion instead of receiving destructive guesses.
- Target capability and caret ownership become explicit system-boundary
  concepts with focused tests.
- Cursor presentation observes transcription state but never joins the HID
  callback-to-action hot path.
- Real terminal compatibility remains an integration gate because
  Accessibility implementations differ by terminal.
