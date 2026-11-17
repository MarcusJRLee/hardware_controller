# macOS text delivery

- **Status:** Accepted
- **Updated:** 2026-11-17
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
| Editable (settable selected text) element in `AXWebArea` | Transcript HUD     | One buffered Unicode event through `cghidEventTap`. |
| Secure, unfocused, changed, or unknown                | None                  | No automatic delivery; explicit copy recovery. |

## Decision

**Target capture**

- When a session begins, capture the focused app and editable element. Reject
  secure fields. Record a composition lease: element and process identity,
  insertion range, and supported operations, without reading the field value.
- Classify in order: validated terminal, web content, then native
  Accessibility capability. Terminal means native Terminal with an empty
  readable range, or Cursor only when its focused element identifies a
  terminal or shell. Web content means an element with settable selected text
  inside the standard `AXWebArea` role, including an editable web area itself;
  never inspect browser, site, or field identity. A focused web area or group
  without settable text is a page with no editable focus, never a target.
- Chromium-family browsers build page accessibility only after an
  application-level request; asking for the focused element never triggers
  it. Until then the first capture sees no focus, a bare group, or the web
  area. On its first such read, capture asks the frontmost app for its role,
  which wakes the tree, then re-reads every 10 ms for up to 500 ms before
  failing with no text field. Secure fields and existing selections fail at
  once. Capture stays synchronous so commands behind a press keep their
  order. Brave rejects `AXManualAccessibility` and `AXEnhancedUserInterface`.

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
  Web carets compare by `AXSelectedTextMarkerRange` when the target exposes
  one: numeric offsets also count text around the field, so an empty Gemini
  prompt flips between 10 and 38 while its caret never moves. Markers stay
  equal across those flips and change when the caret moves.
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
- Measured 2026-11-17 on Brave 1.99.55 (Chromium 157) against
  gemini.google.com in a fresh profile with the editor focused. Before: the
  first press failed in 3 of 4 trials (no text field, a changed caret, or
  keystrokes sent to the page body from a web-area target) and the next
  press worked. With the wake: capture took 32–50 ms and 5 of 6 first
  presses landed with a 1 s hold; every miss was the 10↔38 offset flip,
  which appears about 1 s after the wake. Marker revalidation is unit-tested;
  a live Gemini run with it is still open.
- `scripts/check_web_text_delivery.sh` proves a cold first press on a local
  Gemini-shaped page in about 1.5 s. It focuses a throwaway browser window,
  so it is opt-in, not part of `scripts/install_app.sh`.
