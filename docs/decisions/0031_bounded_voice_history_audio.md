# 0031 — Bound Voice History audio independently from transcripts

## Status

Accepted and implemented for macOS M7.

## Context

M6 retains one optional CAF beside immutable, searchable session and result
evidence. Without automatic bounds, successful Dictation can grow storage
indefinitely. Cleanup must not remove an active recording, pinned audio, or the
only recovery artifact for a failed or incomplete delivery.

## Decision

- Configure age, total audio bytes, and retained-audio count independently.
  `Unlimited` is explicit; zero means retain no eligible completed audio.
- Default macOS to 90 days, 2 GiB, and 5,000 audio artifacts. Reserve the
  accepted iOS default of 90 days, 1 GiB, and 2,000 artifacts in the portable
  policy without applying it to macOS preferences.
- Evaluate age first, then count, then bytes, then low disk. Within each rule,
  select by session end time and UUID so ties are deterministic.
- When the byte cap is exceeded, reclaim to 90% of the cap. Low-disk cleanup
  restores a 1 GiB reserve when the local volume reports less basic available
  capacity. Do not call the synchronous CacheDelete-backed important-usage key.
- Exclude active, pinned, failed, and not-attempted sessions from automatic
  expiration. Protected audio still counts toward limits, and an unmet cap or
  low-disk request remains visible as typed maintenance evidence.
- Quarantine the selected CAF, atomically clear its database reference while
  recording expiration time and reason, then remove the quarantine. Restore
  the original file when the database transaction fails. M8 owns reconciliation
  if final quarantine removal fails or a prior crash leaves partial/orphan data.
- Keep duration, timed spans, immutable text results, search, and export
  metadata after audio expires. Export schema revision 2 includes optional
  expiration time and reason.
- Use one shared History service for capture, browsing, preferences, and
  maintenance. Run policy and SQLite/file work on actors after finalization and
  at first startup access, outside hardware callbacks, target validation, and
  text insertion.
- Request OS-backup exclusion for the owned Voice History root on supported
  volumes. Manual copies, filesystem snapshots, and external backup tools remain
  outside app control.

## Consequences

- General exposes restrained preset choices while the versioned preference
  schema supports any validated value within the portable policy bounds.
- History states why playback is unavailable and retains all reusable text.
- Missing or unreadable artifacts do not block cleanup of unrelated sessions.
- Automatic cleanup is storage lifecycle management, not secure erasure; SSD
  wear leveling, snapshots, and external backups remain outside its guarantee.

## Evidence

Pure-policy tests cover defaults, `Unlimited`, zero, protected artifacts,
stable ordering, the byte low-water mark, low disk, invalid sizes, and invalid
configuration. SQLite tests cover startup and post-finalization enforcement,
concurrent finalization, corrupt or missing sizes, recovery protection,
expiration provenance, stale maintenance ordering, capacity inspection failure,
wall-clock rollback, concurrent pin protection, search preservation, and export
without audio. The complete 451-test/69-suite corpus passes. Measured
5,000-session warm-search p95 is 2.615 ms against the 250 ms requirement;
packaged-UI evidence is recorded in the game plan.
