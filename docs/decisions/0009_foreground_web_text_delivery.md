# 0009: Foreground web-content text delivery

- **Status:** Accepted; implemented in version 1.3.3
- **Date:** 2026-07-28
- **Amends:**
  [`0006_adaptive_live_transcription.md`](0006_adaptive_live_transcription.md)
  and
  [`0007_quiet_terminal_delivery.md`](0007_quiet_terminal_delivery.md)

## Context

Renderer-hosted web fields can report settable selected text and a stable
selection range without honoring the synchronous mutation contract required by
live Accessibility composition. Physical testing in a Google search field
reproduced a stale-caret failure that stopped Dictation while the control
remained held.

A process-targeted Unicode marker reached the browser's native URL field but
not its focused web field. The same marker reached the web field when posted
through the foreground HID event path. This isolates event routing from browser
or website identity.

## Delivery decision matrix

| Criterion | Retry live Accessibility | Foreground events for every target | Semantic buffered foreground events |
| --- | --- | --- | --- |
| Reaches renderer-hosted fields | Unproven. | Yes. | Yes. |
| Preserves native live composition | Yes. | No. | Yes. |
| Preserves validated terminal routing | Yes. | No. | Yes. |
| Avoids browser and website lists | Yes. | Yes. | Yes. |
| Avoids ambiguous replay | No. | Yes. | Yes. |

## Decision

- Classify editable descendants of the standard `AXWebArea` role as buffered
  foreground-event targets. Do not inspect browser bundle identifiers,
  websites, domains, or field-specific labels.
- Keep validated native Terminal and Cursor terminal classification first.
  Those targets retain captured-process event delivery.
- Require a readable empty selection range when the target is captured. Buffer
  all recognition updates until finalization and show provisional text only in
  the temporary transcript HUD.
- Immediately before delivery, revalidate the same foreground application,
  focused element, and unchanged caret. Post one sanitized Unicode payload
  through `cghidEventTap`.
- Never combine Accessibility insertion and event insertion in one session.
  Never synthesize Return, deletion, modifiers, or pasteboard changes.
- Keep native controls and non-web editors on their existing Accessibility
  capability paths.

## Consequences

- Web-content delivery is browser-independent and website-independent.
- Native browser controls such as the URL field retain live Accessibility
  behavior because they are not descendants of `AXWebArea`.
- Cursor's integrated terminal retains captured-process delivery. A Cursor
  editor exposed as web content uses buffered foreground delivery rather than
  unsafe live composition.
- Foreground delivery remains final-only because revising provisional text
  would require destructive synthetic deletion.
- Browser, Cursor, Terminal, focus-change, and no-submission behavior remain
  physical release gates. The 1.3.1 artifact does not contain this change.

## Evidence

On July 28, 2026:

- Google Search and Google Docs reproduced the live-composition caret failure;
- process-targeted Unicode reached the browser URL field but not Google Search;
- foreground-routed Unicode reached the same Google Search field;
- automated policy, controller, writer, and event-boundary tests passed while
  retaining the existing Terminal and Cursor terminal routes.
