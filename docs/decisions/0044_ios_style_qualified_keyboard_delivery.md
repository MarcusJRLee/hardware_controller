# Decision 0044: iOS Style-qualified keyboard delivery

**Status:** Accepted; amended by [decision 0048](0048_ios_bounded_insertion_recovery.md)

## Context

The keyboard must choose a Style without knowing the host application, and the
containing app must apply that exact choice after local ASR. Reading one mutable
preference during finalization could format an in-flight session with a newer
selection. Linking the formatter into the extension would also widen the
handoff and runtime boundary.

| Criterion | Style on exact stop command | Read mutable shared preference | Format in keyboard extension |
| --- | --- | --- | --- |
| In-flight session determinism | Selected | Selection can race finalization | Deterministic |
| Extension isolation | Only one bounded identifier crosses | Shared preference crosses | Formatting code and evidence cross |
| Canonical macOS parity | Exhaustive typed mapping | Exhaustive typed mapping | Duplicated formatter boundary |
| Offline operation | Yes | Yes | Yes |
| Reviewable migration | Command schema revision 2 | Preference schema required | Larger extension change |

## Decision

- Define five stable handoff identifiers: Natural, Casual Message, Formal,
  Technical, and Verbatim. Exhaustively map them to the canonical shared Swift
  `VoiceStyle` values inside the containing app.
- Persist separate app and keyboard surface defaults in each process's local
  `UserDefaults`. Only the keyboard's selected identifier on an exact stop
  command crosses the same-team Keychain boundary.
- Require Style on schema-revision-2 stop commands. Start commands carry no
  Style. Consume but reject legacy, future-dated, stale, or malformed commands
  without finalizing a result.
- Capture the in-app Style when its stop begins. Capture the keyboard Style when
  its stop command is written. Later preference changes cannot alter either
  in-flight session.
- Claim insertion durably in the bounded same-device Keychain record before
  changing the host field. Deduplicate by session identity, so a re-published
  ready snapshot remains already inserted even if its sequence is higher. A
  crash after the claim can produce no insertion, but cannot replay one; History
  remains the recovery source.
- Keep the keyboard a full QWERTY keyboard without Full Access. The Style menu
  changes local preference only; microphone and Keychain handoff remain
  unavailable until Full Access is confirmed.

## Verification

Focused tests cover stable identifiers and labels, preference validation,
exhaustive domain mapping, schema migration, stale commands, exact Style
finalization, real-Keychain stop/ready handoff, and session-level exactly-once
decision plus durable at-most-once claiming. The containing-app UI exposes the
selector by accessibility identity.
The signed-device build must continue proving that neither extension links Rust,
whisper.cpp, model resolution, SQLite History, or formatting runtime code.

## Implications

I2 and I6 are implemented in source. Final physical-iPhone keyboard evidence is
still required; the paired phone currently rejects another development app
because its free provisioning profile already has three unrelated apps
installed. Removing one is a user-owned destructive choice and is not performed
automatically.

## Amendment

Decision 0048 preserves the durable claim before the first host-field side
effect and every automatic replay guarantee. It adds one explicitly requested,
process-local retry after an unconfirmed attempt. That retry never survives an
extension restart and requires the exact claimed result and unchanged target.
