# Voice History

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0030, 0031, 0032, 0036, 0038, 0043

## Context

Voice sessions need durable, searchable evidence for recovery and reuse
without rewriting what was captured, growing storage without bound, losing a
recording to a crash, or targeting a field the user did not choose. macOS and
iOS must share the same semantics without sharing a database layout.

| Criterion                     | Portable V1 archive directory | SQLite copy | Platform JSON |
| ----------------------------- | ----------------------------- | ----------- | ------------- |
| Verifiable without Apple code | 🟢 Rust verifier.             | 🔴 No.      | 🟠 Swift only. |
| Safe bounded import           | 🟢 Exact inventory and caps.  | 🟠 Whole DB.| 🟡 Partial. |
| Reuse on later platforms      | 🟢 Schema and fixtures.       | 🔴 Layout-bound. | 🟠 Per platform. |

## Decision

**Sessions and results**

- A session has at most one audio file (CAF) and an append-only graph of
  immutable results: Raw, Edited, Formatted, Delivered, and every correction,
  retranscription, reformat, or re-delivery, each with typed provenance. Only
  metadata such as pin state changes in place.
- Raw is immutable ASR output. Spoken edits (backtrack, sentence delete,
  paragraph, numbered and bulleted lists, literal escape) become typed
  operations with UTF-8 evidence, replayed strictly to produce Edited;
  ambiguous or near-match commands stay literal, and Dictionary replacements run
  afterward. The same Core sources run on iOS.
- Search covers every stage. Timed spans are bounded by measured duration.
  Explicit re-delivery waits three seconds, captures and validates a fresh empty
  caret, and appends a result either way.
- Importing a recording (macOS **Import Audio Recording**) streams it in
  4,096-frame buffers into an app-owned CAF, bounded by source bytes, decoded
  bytes, and duration (defaults 2 GiB, 2 GiB, 12 h). It runs the same ASR and
  Style, never inserts text, keeps no external path, and records
  `importedAudio` provenance.
- Deletion is transactional: quarantine the CAF, commit, then remove it.

**Retention**

- Age, total audio bytes, and audio count are independent; `Unlimited` is
  explicit and zero keeps no eligible audio. Defaults: macOS 90 days, 2 GiB,
  5,000; iOS 90 days, 1 GiB, 2,000.
- Evaluate age, count, bytes, then low disk, ordered by end time and UUID. A
  byte cap reclaims to 90%. Low disk restores a 1 GiB reserve using basic
  available capacity, never the synchronous important-usage key.
- Active, pinned, failed, and not-attempted sessions are never expired
  automatically; they still count toward limits, and an unmet cap is reported.
- Expiring audio keeps the session, text, spans, search, and a typed reason.
  Quarantine the CAF, clear its reference in a transaction, then remove it;
  restore it if the transaction fails.
- Run maintenance after a durable commit, at first History access, and after a
  settings change, on actors outside hardware callbacks, targeting, and
  insertion. On iOS a post-commit maintenance failure is shown but never
  invalidates the commit. SQLite connections, including startup's read-only
  corruption check, share a five-second contention bound, so a closing or
  still-maintaining connection delays startup instead of failing it.
- The policy itself is the single Rust planner
  ([portable_voice_engine](portable_voice_engine.md)).

**Crash recovery**

- Before first retention, one idempotent reconciler adopts only exact app-owned
  names (`<session>.partial`, `<session>.caf`, `.expiring_<session>_<op>.caf`)
  and ignores everything else.
- Committed expiration quarantine is discarded; uncommitted quarantine is
  restored. Readable partial or orphaned audio becomes a Recovery session with
  empty truthful stages and `notAttempted` delivery, playable and
  retranscribable. Rename to the canonical CAF before inserting the row.
- Unpinned Recovery audio expires after 24 hours with reason `recovery_limit`.
  Unreadable owned audio is kept for that interval.
- A malformed row is isolated; a physically corrupt database is preserved as
  `history_corrupt_*` before clean storage is created. Ordinary open,
  permission, or disk errors are not corruption.
- If audio finalization fails, the text still commits and the audio failure is
  shown.

**Archives**

- Export one `.voice_history` directory containing exactly `manifest.json`
  (V1 session, results, retention, Recovery, pin), `checksums.json` (SHA-256 of
  manifest and audio), and optional `audio.caf`. Schemas live in `schemas/`;
  Swift and Rust both accept `Tests/cuj/voice_history_archive_v1/valid`.
- macOS snapshots a chosen archive into a private `0700` directory, has Rust
  verify the inventory, sizes, identities, and digests, then restores
  transactionally and applies retention. Caps: manifest 16 MiB, checksums
  256 KiB, audio 2 GiB, 10,000 results.
- Identical imports are no-ops that keep newer local pin and retention state; a
  UUID with different evidence is a visible conflict. Revision 4
  `session.json` packages still import on macOS. Checksums prove integrity, not
  publisher.

**Storage**

- History roots, databases, and audio use Complete Until First User
  Authentication protection where available and request backup exclusion.
  Retention is lifecycle management, not secure erasure.
- iOS stores sessions in its own SQLite adapter, commits before publishing any
  result, and persists retention settings as a versioned envelope in
  `UserDefaults`; future or invalid settings are preserved and make the
  controls read-only.

## Consequences

- Earlier evidence stays inspectable after every correction or rerun, and a
  crash produces a visible Recovered item instead of silent loss.
- Capture and delivery never wait on History.
- Evidence: 5,000-session warm search p95 2.639 ms against a 250 ms budget.
- Still to build on iOS: export, correction, and retranscription.
