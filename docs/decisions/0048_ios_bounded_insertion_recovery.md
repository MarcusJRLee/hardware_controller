# Decision 0048: iOS bounded insertion recovery

**Status:** Accepted

## Context

`UITextDocumentProxy.insertText` has no success result. A host may accept the
text without immediately producing a keyboard text-change callback, so absence
of a callback cannot prove failure. Recovery must remain useful without turning
an ambiguous result into automatic duplicate delivery, persisting host context,
or weakening the durable session claim.

| Criterion | Automatic retry | No retry; History only | Explicit bounded retry and local copy | Retained host-text fingerprint |
| --- | --- | --- | --- | --- |
| Duplicate-delivery control | Weak | Strong | Selected: user acknowledges ambiguity | Partial |
| Same-target enforcement | Current field only | Not applicable | Exact in-memory session/document/revision | Content-dependent |
| Recovery speed | Immediate | Requires app switch | One keyboard action | One keyboard action |
| Extension restart | May replay | History | History | Fingerprint unavailable |
| Target-content retention | None | None | None | Required |

## Decision

- Keep automatic delivery to one attempt. Write the durable same-session
  insertion claim before that attempt, and never retry automatically.
- After an attempt, wait 500 milliseconds for a UIKit text-change callback. If
  none arrives, say only that no field update was confirmed; do not claim that
  insertion failed.
- Retain one process-local recovery value containing the exact session, result
  sequence, delivered text, and pre-existing ephemeral delivery target. Do not
  persist it or retain host text, cursor context, semantic traits, or app
  identity.
- Before every recovery action, require Full Access, a recognized general-text
  field, the exact current schema/Ready/session/sequence/text snapshot, its
  durable insertion receipt, and the same UIKit document and host-change
  revision. Any mismatch directs the user to containing-app History.
- Permit one explicit insertion retry per extension process. After that attempt,
  offer copy or History only. This deliberate user action can duplicate text if
  the host accepted an earlier attempt without a callback; the bounded UI copy
  exposes that ambiguity.
- Offer explicit copy through a local-only pasteboard item capped at 256 KiB of
  UTF-8 and expiring after ten minutes. `localOnly` prevents Universal
  Clipboard transfer; the item remains available to paste targets on this
  device until expiry. History exposes the same bounded copy action. The
  product never reads pasteboard contents.
- Treat text callbacks as confirmation and selection callbacks as target
  invalidation. Losing Full Access, changing field state, receiving a different
  result, restarting the extension, or leaving the keyboard discards recovery
  state; the transcript remains in History.

## Verification

Pure policy tests cover the one-retry boundary, exact target/session/sequence/
text/receipt requirements, untrusted snapshot phases and schema, UTF-8 byte
limits, expiry, and invalid configuration. Focused simulator builds exercise
the app, keyboard, and shared framework together. Physical-iPhone evidence must
still confirm callbacks and host-specific rejection behavior after one unrelated
development app is removed from the paired phone.

## Implications

I9 is implemented without weakening crash/restart replay protection. Delivery
is at-most-one automatic attempt, not provably exactly once: UIKit exposes no
atomic insert-and-confirm operation. History remains authoritative whenever
target continuity cannot be demonstrated.

This decision amends decisions
[0044](0044_ios_style_qualified_keyboard_delivery.md) and
[0045](0045_ios_host_field_and_delivery_target_safety.md).

## Sources

- [Apple text interaction callbacks](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [Apple text document proxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy)
- [Apple pasteboard item options](https://developer.apple.com/documentation/uikit/uipasteboard/setitems(_:options:))
- [Apple local-only pasteboard option](https://developer.apple.com/documentation/uikit/uipasteboard/optionskey/localonly)
- [Apple pasteboard expiration option](https://developer.apple.com/documentation/uikit/uipasteboard/optionskey/expirationdate)
