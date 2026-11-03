# macOS text delivery

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0002, 0006, 0007, 0009, and the delivery part of 0005

## Context

Bridging the system Dictation shortcut could not observe or own Dictation
state, so the app owns transcription and must type into the focused app
itself. Editors, browsers, and terminals expose different Accessibility
capabilities, recognition revises earlier words, and a failed system call can
have ambiguous effects. Delivery must never duplicate, submit, or touch the
clipboard on its own.

| Target evidence                                      | Provisional text      | Final delivery |
| ---------------------------------------------------- | --------------------- | -------------- |
| Stable readable and settable selection range          | Live, in the field    | Commit the session-owned span in place. |
| Settable selected text, no stable range               | Transcript HUD        | `AXSelectedText` insertion of final text. |
| Validated terminal (Terminal, Cursor's terminal)      | Transcript HUD        | One buffered Unicode event to the captured process. |
| Editable descendant of `AXWebArea`                    | Transcript HUD        | One buffered Unicode event through `cghidEventTap`. |
| Secure, unfocused, changed, or unknown                | None                  | No automatic delivery; explicit copy recovery. |

## Decision

**Target capture**

- When a session begins, capture the focused app and editable element. Reject
  secure fields. Record a composition lease: element and process identity,
  insertion range, and supported operations, without reading the field value.
- Classify in order: validated terminal, web content, then native
  Accessibility capability. Terminal means native Terminal with an empty
  readable range, or Cursor only when its focused element identifies a
  terminal or shell. Web content means any editable descendant of the standard
  `AXWebArea` role; never inspect browser, site, or field identity.

**Live composition**

- Normalize both Apple recognizers into one cumulative revision of committed
  and provisional text.
- Compose live only from an empty initial selection on a target with a
  readable and settable range. Before each replacement, verify the same element
  and expected caret, and replace only the previously inserted span. Commit
  final text in place; on cancellation remove the owned span.
- If focus or caret ownership changes, stop mutating and keep recoverable text.

**Buffered delivery**

- Terminal and web targets buffer until recognition finalizes, then revalidate
  the same app, element, and caret before posting one sanitized payload.
- Replace CR, LF, and tab with spaces and strip other controls. Never
  synthesize Return, Enter, modifiers, escape sequences, or deletion.
- Never use Accessibility and event insertion in one session, never replay
  automatically, and never change the pasteboard automatically. Offer explicit
  **Copy transcript** instead.
- Same-process insertion runs on the main thread (AppKit traps otherwise);
  external insertion stays off the main actor.

**Presentation**

- Show the transcript HUD only when the target cannot show provisional text
  and there is text to show. Hide it at completion or failure; Settings and the
  menu bar keep the authoritative state.
- Place the HUD at the caret when its bounds are known, else at one stable spot
  near the active screen edge. Never follow the pointer or poll.
- Use shape and text as well as color, and respect Reduce Motion and Increase
  Contrast.

## Consequences

- Compatible editors show words as the user speaks; terminals and web fields get
  final text through the path they actually consume, without submitting.
- Some custom editors expose no settable selection; their failure is visible and
  recoverable, not hidden behind a clipboard change.
- Physical evidence from the 1.3.0 build: dictation reached native Terminal and
  Cursor's zsh terminal at an unchanged caret without submitting. Browser,
  Cursor, Terminal, focus-change, and no-submission behavior stay release
  gates.
