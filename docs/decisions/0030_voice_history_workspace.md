# 0030: Voice History workspace

- **Status:** Accepted
- **Date:** 2026-08-26

## Context

Local AI Dictation already retains one local audio artifact and distinct final
text stages. Recovery and later reuse need durable provenance without creating a
second macOS app, rewriting capture evidence, or silently targeting a newly
focused field.

## Decision matrix

| Criterion | Fourth sidebar destination | Separate History window | Controller disclosure |
| --- | ---: | ---: | ---: |
| Keeps one application and navigation model | 5 | 2 | 5 |
| Makes recovery discoverable | 5 | 4 | 2 |
| Scales to searchable archive work | 5 | 5 | 1 |
| Keeps Controller device-centered | 5 | 5 | 1 |
| Uses native macOS structure | 5 | 3 | 3 |
| **Total** | **25** | **19** | **12** |

## Decision

Add **History** as the fourth destination in the existing AppKit-owned window.
Keep each Voice session immutable except for session metadata such as pin state.
Represent every Raw, Edited, Formatted, Delivered, corrected, retranscribed,
reformatted, or re-delivered value as a linked immutable result with typed
provenance. Existing sessions receive lazy baseline-result backfill without row
rewrites.

Search all result stages. Retain at most one CAF per session and bound every
timed span to its measured duration. Reuse the current local speech and model
adapters. Explicit re-delivery waits three seconds, then captures and validates
a fresh empty caret before mutation; success and failure both append results.

Export one versioned `.voice_history` package containing `session.json`,
streaming SHA-256 `checksums.json`, and at most one copied CAF. Pin state
anticipates M7 eviction. Deletion removes the session metadata and owned audio
transactionally, quarantining the file until the database commit succeeds.

Decision [0036](0036_imported_voice_audio.md) adds typed imported-audio input
provenance and advances the export manifest to revision 4. Older documents and
database rows decode as microphone capture.

## Consequences

- Decision [0013](0013_application_navigation.md) remains the historical source
  for the one-window navigation choice but no longer defines destination count.
- Capture and delivery stay independent from History presentation and storage
  latency.
- Earlier evidence remains inspectable after every correction or rerun.
- Decision [0031](0031_bounded_voice_history_audio.md) owns automatic quota and
  low-disk expiration. Decision [0032](0032_voice_history_crash_recovery.md)
  owns partial, orphan, quarantine, and corrupt-state reconciliation.
- Exported packages are portable evidence, not a second mutable database.

## Evidence

Swift unit and SQLite-reopen tests cover result linking, migrations, search,
corruption isolation, timed spans, operations, export, playback, and deletion.
A 5,000-session warm-search benchmark must remain within 250 ms p95. Packaged
UI checks cover the History route, search, correction, appearance modes, large
text, increased contrast, and reduced motion.
