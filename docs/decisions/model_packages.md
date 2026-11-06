# Model packages and downloads

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0037, 0041, 0061, 0062

## Context

Speech runtimes need several model, configuration, and notice files that are
large and untrusted. A file digest proves consistency with its manifest but not
that the manifest is authentic. A fresh iOS install also has to dictate with no
Mac-side step, and better models should be one tap away on both apps.

| Criterion                    | Pinned manifest + file digests | Self-declared digests | Trust the name |
| ---------------------------- | ------------------------------ | --------------------- | -------------- |
| Detects corruption           | 🟢 Yes.                        | 🟢 Yes.               | 🔴 No. |
| Authenticates downloads      | 🟢 Out-of-band manifest pin.   | 🔴 No.                | 🔴 No. |
| Allows manual imports        | 🟢 Labeled unverified.         | 🟢 Yes.               | 🟡 Yes. |
| Bounds path attacks          | 🟢 Canonical inventory.        | 🟡 Partial.           | 🔴 No. |

| Criterion                    | Shared pinned downloader | Bundle every model | iOS-only downloader |
| ---------------------------- | ------------------------ | ------------------ | ------------------- |
| App size                     | 🟢 +0 MB.                | 🔴 +1.1 GB.        | 🟢 +0 MB. |
| One implementation           | 🟢 Both apps.            | 🟢 No fetch.       | 🔴 Two to drift. |
| Network exposure             | 🟡 HTTPS on tap only.    | 🟢 None.           | 🟡 Same, twice. |

## Decision

**Package format**

- A Model package is a private directory with `manifest.json` and only its
  declared payload.
  [`voice_model_package_v1.schema.json`](../../schemas/voice_model_package_v1.schema.json)
  is the publisher format; the Rust validator (`voice_models`, exposed by
  `voice_ffi`) is the authority.
- The manifest carries identity, version, display name, runtime, one stage and
  its capabilities, up to 256 languages, SPDX expression, notice, HTTPS source,
  memory needs, and each file's role, exact bytes, and SHA-256. A notice file is
  mandatory; validation records license evidence, not legal compatibility.
- Default caps: 1 MiB manifest, 8 GiB package, 4,096 files, all configurable.
  Reject absolute, traversal, empty-segment, backslash, colon, control, and
  overlong paths, symlinks, undeclared or missing files, and size or digest
  mismatches.
- Downloads and the bundled starter pass an expected manifest SHA-256 and are
  shown **Verified**. Manual imports omit it and are shown **Manual import**.

**Installation (iOS)**

- Copy into private staging with independent entry, file, and byte bounds,
  rejecting links. Paths are taken relative to the source, because a device
  lists its container as `/private/var` while the app spells it `/var`. Rust
  then validates, and the directory moves atomically to `package_id/version`.
- Identical installs are idempotent; different bytes under one identity fail.
  Stale staging is removed. Installed packages use one canonical root path.
- The library caps total bytes (12 GiB) and versions (eight). Admission never
  evicts; only an explicit removal does, through a private quarantine.
- Packages use Complete Until First User Authentication protection and are
  excluded from backup. A protected sidecar records the manifest digest and
  whether it was publisher verified.
- Admission does not select a runtime; selection persists package ID, version,
  and digest ([asr_runtime](asr_runtime.md)).

**Bundled starter (iOS)**

- `scripts/prepare_ios_build_inputs.sh` regenerates Whisper Tiny English with
  Silero VAD (45 MB) from pinned assets; the app bundles it as
  `starter_asr_model`.
- On the first library refresh of a launch, if nothing is selected and no other
  compatible package exists, install it with its pinned digest and select it. A
  user-installed model always wins; an invalid saved selection is still shown as
  an error.

**Downloads (both apps)**

- `Sources/hardware_controller_model_download` holds the catalog, an HTTPS-only
  fetcher, and an assembler that verifies each file's pinned size and SHA-256,
  then writes the notice and manifest and returns its digest. Revisions are
  immutable Hugging Face commits; changing a pin is a reviewed change to
  `asr_model_catalog.swift`.
- The Mac downloads Parakeet TDT 0.6B v3. Voice Input offers Whisper Base
  English (85 MB), Whisper Small English (270 MB), and Parakeet (741 MB), and
  selects a download once it is installed.
- A download starts only from an explicit tap, uses an ephemeral session with no
  cookies, cache, or credentials, refuses non-HTTPS redirects, and never sends
  audio or text. Staging is excluded from backup and removed on any failure.

## Consequences

- Every platform admits identical package bytes under one policy.
- Dictation works on a fresh iOS install; a unit test fails if the bundled
  manifest drifts from its pin.
- Checks keep the fetcher the only network code besides the Ollama adapter, and
  out of the iOS keyboard and widgets
  ([local_only_boundary](local_only_boundary.md)).
- Building iOS needs Rust's `aarch64-apple-ios` and `aarch64-apple-ios-sim`
  targets.
