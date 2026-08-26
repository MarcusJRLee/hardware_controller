# 0032 — Reconcile Voice History crash artifacts before retention

## Status

Accepted and implemented for macOS M8.

## Context

Voice audio crosses a filesystem/SQLite transaction boundary. Process death can
leave a partial recording, a finalized CAF without a session row, or a
quarantined CAF whose expiration transaction either committed or rolled back.
One malformed row or database file must not hide unrelated History. Audio
finalization failure must not discard completed transcript evidence.

## Decision

- Run one idempotent reconciliation actor before first-access retention. Keep
  capture, HID dispatch, target validation, and delivery outside this work.
- Recognize only app-owned exact names: `<session>.partial`, `<session>.caf`,
  and `.expiring_<session>_<operation>.caf`. Ignore every other file.
- Use database evidence to discard committed expiration quarantine or restore
  uncommitted quarantine. Convert readable partial, orphan, and otherwise
  unowned quarantine audio into a Recovery session without inventing text.
- Give one artifact the original unclaimed session identifier; allocate a new
  identifier for collisions. Rename to the canonical CAF before inserting the
  row so another interruption leaves an idempotently recoverable orphan.
- Store Recovery kind and reconciliation time beside four empty baseline
  stages with `notAttempted` delivery. Permit local playback and retranscription.
  Export schema revision 3 carries the Recovery provenance.
- Expire unpinned recovered audio 24 hours after reconciliation with the typed
  `recovery_limit` reason. Preserve its searchable session and result graph.
  Preserve recent unreadable owned audio for that interval; remove stale,
  unreferenced unreadable audio through an explicit planner action.
- Isolate a malformed SQLite session/result row and continue returning valid
  rows with sanitized typed evidence. When SQLite itself is physically corrupt,
  preserve its database family under a unique `history_corrupt_` name before
  creating clean local storage. Do not classify ordinary open, permission,
  coordination, or disk errors as corruption.
- If CAF finalization fails, commit the completed text document without audio,
  then surface the typed audio failure. Unrelated sessions remain available.

## Consequences

- A crash can produce a visible Recovered History item instead of silent data
  loss. Empty recovery stages remain truthful and become reusable only after
  retranscription or correction.
- Whole-file playback covers recovered and legacy audio without timed spans.
- Startup repair failures preserve the artifact for a later launch and do not
  stop independent repair actions.
- Physical database preservation is recovery evidence, not verified salvage;
  the app does not claim to reconstruct unreadable SQLite contents.

## Evidence

Pure planner tests cover deterministic expiration repair, orphan identifier
ownership, quarantine recovery, unrelated-file exclusion, and the 24-hour
unreadable rule. Real AVFAudio/SQLite tests cover partial recovery and
retranscription, expiration restore/discard, recovered-audio expiry, full-disk
audio failure, malformed-row isolation, unreadable artifacts, and physical
database preservation. Presentation and export tests cover empty-result
selection, sanitized recovery copy, and revision-3 provenance. The current
corpus passes 475 tests in 71 suites; 5,000-session warm search p95 is 2.639 ms
against the 250 ms requirement. Signed packaged-UI checks cover light, dark,
increased-contrast, reduced-motion, large-text, and keyboard-navigation modes.
