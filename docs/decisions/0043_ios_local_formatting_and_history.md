# Decision 0043: iOS local formatting and History

**Status:** Accepted

## Context

iOS file ASR produced timed Raw text, but publishing it immediately would lose
the accepted Raw/Edited/Formatted separation, spoken backtracking, semantic
lists, retained recordings, and recovery after insertion failure. The iOS path
must reuse macOS behavior without importing hardware, AppKit, or the larger
macOS History implementation into the mobile target.

| Criterion | Shared deterministic Swift core + iOS SQLite adapter | Duplicate iOS rules | Rust rewrite now |
| --- | --- | --- | --- |
| Same spoken-edit/semantic fixtures as macOS | Exact source reuse | Drift-prone | Requires new parity work |
| Strict Swift 6 integration cost | Low | Low | Higher FFI/schema expansion |
| Later Android/native-desktop reuse | Schemas and retention already portable; behavior can migrate behind the same contract | Low | High |
| iOS system integration | Native SQLite, Data Protection, AVFAudio | Native | Adapter still required |
| First complete vertical slice | Selected | Rejected | Deferred until measured value justifies it |

## Decision

- Compile only the platform-neutral spoken-edit, formatting, renderer, Style,
  and retention sources into a static iOS core target. Keep Apple capture,
  playback, Keychain, SQLite, and filesystem adapters in the containing app.
- Treat whisper output as immutable Raw evidence. Apply explicit spoken edits
  to create Edited, then build and validate semantic paragraph/list blocks and
  render Formatted. Compile the same typed casing transformer, list-intent
  detector, draft normalizer, and revisioned spoken-list engine into the
  portable target, and invoke them in the iOS document pipeline so iOS and
  macOS share deterministic list semantics. Verbatim bypasses spoken commands
  and preserves literal text unless an explicit casing policy is applied.
- Copy each completed CAF through a protected partial file, synchronize it,
  atomically finalize it, calculate SHA-256 and bytes, and commit a versioned
  SQLite session containing Raw, Edited, Formatted, Style, spoken operations,
  semantic document, timed segments, and model provenance.
- Publish Formatted text to the shared Keychain only after the History commit
  succeeds. History failure is terminal for that delivery attempt; it cannot
  silently produce untracked keyboard output.
- Apply the accepted configurable iOS defaults of 90 days, 1 GiB, and 2,000
  retained audio artifacts after finalization and History access. Expiration
  removes audio while retaining searchable transcript and typed reason/time.
- On repository startup, delete incomplete partial files and finalized CAFs
  that have no owning row. Protect the owned directory, database family, and
  audio with complete-until-first-authentication Data Protection and exclude
  them from backup. Reject decoded audio metadata unless it resolves to the
  session's canonical app-owned CAF name.
- Keep formatting deterministic in this slice. A later in-process local text
  model may refine a Style only behind the existing evidence validator and
  deterministic Edited fallback.

## Verification

Contract tests share macOS edit/list behavior and prove Raw remains unchanged.
Real iOS SQLite/filesystem tests cover commit/reload, escaped search, SHA-256,
playback state, configured audio expiry with transcript preservation, partial
cleanup, expired-audio crash cleanup, orphan cleanup, natural playback
completion, and explicit close. Finalization tests prove formatted text is
returned only after History accepts every stage. Simulator UI evidence keeps
History and search discoverable without relying on coordinates or private view
hierarchy.

## Implications

I2 now owns real local ASR through durable local formatting and History. Its
remaining acceptance work is explicit Style selection and the complete
one-time signed-device keyboard loop. iOS History intentionally exposes the
first complete capture/search/playback subset; correction, retranscription,
portable archive, pin, export, and transactional deletion remain later slices
under the same canonical domain language.

Decision [0049](0049_ios_offline_storage_enforcement.md) later implements
persisted pinning, configurable presets, low-disk maintenance, and the offline
source boundary for I10. Export, transactional deletion, correction, and
retranscription remain later iOS slices.
