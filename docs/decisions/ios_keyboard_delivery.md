# iOS keyboard delivery

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0044, 0045, 0047, 0048

## Context

The keyboard inserts a result produced by another process, after a delay, into
a host that may have changed fields, rejected the keyboard, or been killed.
`UITextDocumentProxy.insertText` returns no success, so a missing callback
cannot prove failure. Delivery must never land in the wrong field or insert
twice by itself, and must not retain host text or identity.

| Criterion              | Exact opaque target + one explicit retry | Any current field | Retained text fingerprint |
| ---------------------- | ---------------------------------------- | ----------------- | ------------------------- |
| Wrong-field safety     | 🟢 Session, document, and revision must match. | 🔴 None. | 🟡 Content-dependent. |
| Duplicate control      | 🟢 One automatic attempt; retry is the user's call. | 🔴 Weak. | 🟡 Partial. |
| Host data retained     | 🟢 None.                                 | 🟢 None.          | 🔴 Field text. |

| Criterion                   | Heartbeat while Recording and Transcribing | Recording only | Fixed timeout |
| --------------------------- | ------------------------------------------ | -------------- | ------------- |
| Detects app loss while transcribing | 🟢 Yes.                            | 🔴 No.         | 🟡 Eventually. |
| Allows slow local models    | 🟢 Yes.                                    | 🟢 Yes.        | 🔴 No. |

## Decision

**Styles**

- Five stable identifiers (Natural, Casual Message, Formal, Technical,
  Verbatim) map exhaustively to the shared `VoiceStyle`. App and keyboard keep
  separate defaults in their own `UserDefaults`.
- Only the keyboard's Style on an exact stop command (schema revision 2) crosses
  the Keychain. Each surface's Style is captured when its stop begins, so later
  changes cannot alter an in-flight session.

**Fields**

- Voice is offered only in recognized general-text fields. Numeric, credential,
  one-time-code, payment, sensitive-identifier, and unknown custom traits keep
  typing but disable Voice with one generic explanation. iOS already replaces
  the keyboard in secure and phone-pad fields.
- When the keyboard writes a stop, it keeps only an in-memory tuple: session
  UUID, UIKit `documentIdentifier`, and a host-change revision bumped on every
  text or selection callback. All three must match before delivery; otherwise
  the result goes to History.

**Staleness**

- The app publishes a heartbeat every 500 ms while Recording or Transcribing.
  The keyboard treats an active snapshot as stale after three seconds, or if
  its heartbeat is missing, future-dated, or of unknown schema, and then offers
  one **Restart…** action explaining the app or Control Center path.
- The keyboard polls only after writing a stop. Commands older than 30 seconds
  or future-dated are consumed without running. The keyboard never deletes the
  app's slot.

**Insertion**

- Deliver only a result newer than the snapshot that triggered the stop.
  Write a durable same-session insertion claim before the one automatic
  attempt; a claim beats every later or replayed snapshot.
- After the attempt, wait 500 ms for a text callback. Without one, say no field
  update was confirmed, not that it failed.
- One explicit retry per extension process is allowed while Full Access, a
  general-text field, the exact Ready result, its receipt, and the same target
  tuple all hold. The UI says it may duplicate text.
- Explicit copy uses a local-only pasteboard item, at most 256 KiB, expiring in
  ten minutes. The product never reads the pasteboard.
- Losing Full Access, changing fields, a new result, restarting the extension,
  or leaving the keyboard discards recovery; History keeps the transcript.

**Without Full Access**

- The keyboard stays a complete typing keyboard (letters, numbers, symbols,
  shift, delete, return, space, globe). The Style menu changes only local
  preference; Voice and the Keychain handoff wait for Full Access.

## Consequences

- Delivery is at most one automatic attempt, not provably exactly once; UIKit
  has no atomic insert-and-confirm.
- A crash after the claim can lose an insertion but never replay one.
- Neither extension links Rust, the runtime, model code, SQLite, formatting, or
  the download module; `scripts/build_ios_device.sh` checks this.
- Physical evidence still open: callbacks, host rejection, secure-field
  replacement, field switches, and keyboard kill, suspend, and upgrade.
