# 0038: Portable Voice History archives

- **Status:** Accepted
- **Date:** 2026-08-27
- **Supersedes:** The export-format portion of [0030](0030_voice_history_workspace.md)

## Context

The macOS History exporter wrote checksum-protected evidence, but revision 4
used a Swift-owned `session.json` shape and had no restore path. iOS needs the
same immutable session evidence without copying SQLite, trusting filenames, or
silently changing delivery history.

## Decision matrix

| Criterion | Portable V1 directory | SQLite copy | Platform-specific JSON |
| --- | ---: | ---: | ---: |
| Preserves immutable evidence | 5 | 5 | 4 |
| Verifiable without Apple frameworks | 5 | 1 | 2 |
| Safe bounded import | 5 | 2 | 3 |
| Supports schema evolution | 5 | 2 | 3 |
| Reuses across planned platforms | 5 | 1 | 2 |
| **Total** | **25** | **11** | **14** |

## Decision

Use one `.voice_history` directory with exactly:

- `manifest.json`: V1 typed session, result, retention, Recovery, and pin
  evidence;
- `checksums.json`: revision 1, `SHA-256`, and exact manifest/optional-audio
  digests; and
- optional `audio.caf`.

The language-neutral contracts are
[`voice_history_archive_v1.schema.json`](../../schemas/voice_history_archive_v1.schema.json)
and
[`voice_history_archive_checksums_v1.schema.json`](../../schemas/voice_history_archive_checksums_v1.schema.json).
Swift and Rust must both accept the shared fixture under
`Tests/cuj/voice_history_archive_v1/valid`. Rust independently checks the exact
link-free inventory, bounded file sizes, identities, result ownership, and all
declared digests. The versioned C ABI exposes only fixed-layout request and
verified metadata values; it retains no pointers or files.

macOS snapshots a selected archive into a private `0700` temporary directory
before validation or restore. Defaults cap the manifest at 16 MiB, checksum
file at 256 KiB, optional audio at 2 GiB, and results at 10,000; callers may set
stricter positive limits. Restore copies audio into app-owned storage, validates
its measured duration, commits the complete result graph transactionally, runs
normal retention, and never inserts text into another app.

Importing the same immutable document/result evidence is idempotent and keeps
newer local pin/retention state authoritative. The same UUID with different
immutable evidence is a visible conflict and cannot mutate History. The final
pre-portable revision 4 `session.json` package remains readable on macOS and is
migrated into the V1 in-memory contract during import; every new export is V1.

Archive checksums prove internal integrity, not publisher authenticity. This is
user-owned evidence, so no external signature or network lookup is required.

## Consequences

- An archive is at most three files and inherits normal configurable History
  audio retention after restore.
- SQLite files, temporary capture artifacts, and undeclared files never cross
  the archive boundary.
- Future iOS, Android, Windows, and Linux adapters reuse the schema, Rust
  verifier, C ABI, and fixtures rather than database layouts.
- A newer unsupported schema fails closed without deleting or partially
  importing user data.

## Evidence

Swift integration tests cover V1 round-trip with audio, the shared fixture,
revision 4 migration, idempotence, UUID conflict, tampering, undeclared files,
and configurable caps. Rust tests cover the shared fixture, tampering,
inventory, and limits. ABI layout/error tests and an optimized C17 consumer
exercise the static library. The Apple adapter tests both portable fixtures
through the linked Rust symbols, typed buffer negotiation, status translation,
and production V1 import; the release executable is checked for the archive
symbol.
