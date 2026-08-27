# Decision 0049: Enforce offline and bounded iOS storage

**Status:** Accepted

## Context

iOS capture, transcription, formatting, History, and keyboard delivery are
already local. I10 must make that boundary mechanically visible, give users
bounded recording storage, protect selected audio, and prevent cleanup from
turning a durable capture into a failed delivery. Model packages have a separate
budget and must never be mistaken for disposable History cache.

| Criterion | Versioned local settings plus best-effort post-commit maintenance | Fixed limits | Maintenance inside commit |
| --- | --- | --- | --- |
| User control | Exact bounded presets | None | Exact bounded presets |
| Forward-schema safety | Preserve and become read-only | Not applicable | Preserve and become read-only |
| Durable capture under disk inspection failure | Preserved | Preserved | Rejected after successful evidence write |
| Low-disk convergence | Startup, settings change, and post-commit retry | Startup and post-commit | Commit only |
| Selected | Yes | No | No |

## Decision

- Persist iOS History retention in a schema-revision-1 JSON envelope in local
  `UserDefaults`. Missing state uses 90 days, 1 GiB, and 2,000 recordings.
  Invalid or future state is preserved, defaults are used for safety, and the
  controls remain read-only until compatible software can interpret it.
- Expose age, total-audio-byte, and recording-count presets in History.
  `Unlimited` is explicit and zero means retain no eligible completed audio.
  Persist a validated setting before applying it so a maintenance failure
  retries with the user's choice at next History access or launch.
- Run retention after a durable session commit, at History access, and after a
  settings change. Post-commit capacity or filesystem failure surfaces one
  maintenance message but does not invalidate committed transcript/audio
  evidence or block delivery. History commit failure remains terminal.
- Restore a 1 GiB reserve using basic volume-available capacity. Never invoke
  the synchronous important-usage capacity key. Apply age, count, byte
  low-water, and low-disk rules through the shared deterministic planner.
- Advance the iOS History payload to revision 3 with persisted `isPinned`.
  Revisions 1 and 2 migrate to unpinned. Pinning requires retained audio and
  protects successful or Recovery audio from every automatic expiration rule;
  unpinning makes it eligible at the next maintenance pass.
- Keep transcript stages searchable after audio expiration and retain the typed
  expiration reason. Protect the History root, database family, and audio with
  Complete Until First User Authentication and request OS-backup exclusion.
- Keep the Model library's 12 GiB/eight-version admission budget independent.
  Admission over either limit fails closed while every installed package
  remains unchanged. Only an explicit user action removes an installed copy.
- Run a source-controlled local-only check in every iOS verification. It rejects
  network clients, Network.framework linkage, transport-security configuration,
  push, associated-domain, iCloud, and networking capabilities in iOS product
  sources and configuration.

## Verification

Pure and real SQLite/filesystem tests cover revision migration, pin/unpin,
protected Recovery audio, age/count/byte and low-disk expiration, transcript
preservation, unavailable capacity, maintenance failure after commit,
preference defaults/round-trip/validation/future-schema preservation, Data
Protection where CoreSimulator exposes it, and backup exclusion. Model-package
tests prove byte/version admission failure leaves the installed set unchanged.
`scripts/check_ios_local_only.sh` enforces the product's offline source and
capability boundary.

## Implications

I10 is complete in source. Physical airplane-mode capture and on-device file
protection inspection remain part of final signed-iPhone verification; the free
development profile currently prevents installation without removing one of
three unrelated apps.
