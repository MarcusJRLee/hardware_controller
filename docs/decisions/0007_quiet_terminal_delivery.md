# 0007: Quiet transcription presentation and terminal delivery

- **Status:** Accepted
- **Date:** 2026-07-27
- **Amends:**
  [`0006_adaptive_live_transcription.md`](0006_adaptive_live_transcription.md)

## Context

Version 1.2 kept a cursor indicator visible for readiness, completion, and
failure. When Accessibility could not resolve a caret rectangle, a 20 Hz timer
made the compact indicator follow the pointer. Physical use found that
behavior laggy and disruptive.

Version 1.2 also required settable `AXSelectedText` before accepting a target.
The native Terminal's focused shell element exposes a readable empty selection
range and caret bounds but explicitly reports `AXSelectedText` as not settable.
The app therefore rejected Terminal before recognition began. Cursor's
integrated terminal similarly needs terminal-specific validation rather than
being treated as an ordinary document editor.

## Delivery decision matrix

| Target evidence | Provisional text | Final delivery | Safety |
| --- | --- | --- | --- |
| Stable readable and settable Accessibility range | Direct live composition. | Commit the session-owned range in place. | Existing preferred path. |
| Settable selected text without stable range | Temporary transcript HUD. | Finalized Accessibility insertion. | Existing compatibility path. |
| Validated terminal element with stable empty caret range | Temporary transcript HUD. | Buffered Unicode keyboard event sent to the captured process. | New terminal path. |
| Secure, unfocused, changed, or unknown target | No automatic delivery. | Explicit copy recovery only. | Fail closed. |

## Decision

- Do not show a persistent readiness, not-ready, completed, or failure
  indicator near the pointer or caret.
- Show the HUD only when an active target cannot display provisional text
  inline and the session has nonempty transcript text.
- Hide the HUD immediately after completion or failure. Keep authoritative
  failure and recovery state in Settings and the menu-bar surface.
- Never position the HUD relative to the pointer. Prefer a current caret bound;
  otherwise use one stable location near the active screen edge.
- Remove repeating pointer tracking. HUD updates occur only when meaningful
  transcription state changes.
- Treat native Terminal as a buffered terminal target when its focused shell
  element exposes an empty readable selection range.
- Treat Cursor as a terminal target only when its exact application identity
  and focused-element metadata identify a terminal or shell. A Cursor code
  editor remains on the ordinary Accessibility path.
- Buffer terminal text until recognition finalizes. Revalidate the same
  application, element, and caret before posting one finalized payload to the
  captured process.
- Replace carriage returns, line feeds, and tabs with spaces and remove other
  control characters. The terminal adapter must never synthesize Return,
  Enter, modifiers, escape sequences, or deletion.
- Never attempt Accessibility insertion and keyboard-event insertion in the
  same session. A failed system call can have ambiguous mutation semantics, so
  automatic replay could duplicate text.
- Never use the pasteboard automatically.

## Consequences

- The app is visually quiet whenever the target already shows live text or no
  Dictation session is active.
- Terminals receive final text through the input mechanism they actually
  consume, without executing the command.
- Terminal delivery is intentionally final-only because revising provisional
  text would require destructive synthetic deletion.
- Exact Terminal and Cursor behavior remains a release-artifact integration
  gate; API acceptance alone is not evidence of delivery.

## Evidence

On July 27, 2026, the connected native Terminal 2.15 reported:

- role `AXTextArea`;
- role description `text entry area`;
- description `shell`;
- readable empty `AXSelectedTextRange`;
- settable `AXSelectedTextRange`;
- non-settable `AXSelectedText`.

No terminal contents were read or recorded during that capture.

The installed 1.3.0 release artifact then passed physical center-pedal
dictation into both native Terminal and Cursor's integrated zsh terminal.
Finalized text appeared at the unchanged caret after release, and neither
target submitted the command.
