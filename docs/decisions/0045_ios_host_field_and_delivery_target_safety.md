# Decision 0045: iOS host-field and delivery-target safety

**Status:** Accepted

## Context

Apple replaces a custom keyboard in secure and phone-pad fields, and a host app
may reject keyboard extensions entirely. Where Voice Keyboard remains visible,
UIKit exposes a keyboard type, semantic content type, and opaque
`documentIdentifier`. Delivery must not infer the host app or retain field text,
but a result finalized after the user changes fields must not reach the new
cursor.

| Criterion | Typed traits plus ephemeral target | Any current field | Retained text-context fingerprint |
| --- | --- | --- | --- |
| Unsupported-field safety | Selected | No | Partial |
| Late-result target binding | Exact opaque target | None | Content-dependent |
| Target-content retention | None | None | Required |
| Host-app identity | Not used | Not used | May be inferred |
| Extension restart behavior | Recover from History | May misdeliver | Fingerprint unavailable |

## Decision

- Treat only recognized general-text keyboard and content traits as Voice-
  eligible. Numeric, credential, one-time-code, payment, sensitive-identifier,
  and unknown custom traits keep QWERTY available but disable Voice with one
  generic explanation.
- Rely on iOS to replace the extension for secure and phone-pad inputs and for
  hosts that reject third-party keyboards. The extension still rejects those
  traits if UIKit presents them unexpectedly.
- Read no capture snapshot when the current field is unsupported. Retain no
  field text, cursor context, host bundle identity, or semantic trait.
- When the keyboard writes an exact stop, retain only an in-memory tuple of the
  session UUID, UIKit document UUID, and a monotonic host-change revision.
  Increment the revision on every UIKit text or selection callback and validate
  all three values before claiming delivery. A changed field, cursor, text,
  session, or extension process sends recovery to containing-app History.
- Keep the durable Keychain insertion claim after target validation and before
  the host-field side effect, preserving at-most-once delivery.

## Verification

Focused tests cover every normalized field category, known UIKit general and
sensitive traits, unknown custom content types, Full Access independence, and
exact session/document/revision matching. The signed generic-device build must
continue proving extension isolation. Secure-field replacement, host-level
keyboard rejection, and field-switch behavior remain physical-iPhone evidence
because the paired phone is at the three-app free-profile limit.

## Implications

I5 and the safe-delivery portion of I9 are implemented in source. Automatic
delivery intentionally becomes unavailable after extension restart or target
change; the committed History transcript is the recovery source. A later
explicit retry design needs a new target-confirmation contract and cannot reuse
text context or host identity implicitly.

## Sources

- [Apple custom keyboard interface constraints](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
- [Apple document identifier](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentidentifier)
- [Apple text interaction callbacks](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
- [Apple keyboard type](https://developer.apple.com/documentation/uikit/uitextinputtraits/keyboardtype)
- [Apple text content type](https://developer.apple.com/documentation/uikit/uitextcontenttype)
