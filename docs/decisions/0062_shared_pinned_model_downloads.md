# 0062: Offer pinned speech-model downloads on iOS through one shared module

- **Status:** Accepted
- **Date:** 2026-11-02
- **Amends:** [0049](0049_ios_offline_storage_enforcement.md), [0060](0060_macos_transcribe_cpp_default_asr.md), [0061](0061_ios_bundled_starter_model.md)

## Context

Voice Input bundled only Whisper Tiny English. Better models needed a Mac
script, a Files copy, and an import the owner found unusable. The owner asked
for one-tap downloads like the Mac app. iOS had no network code (0049); the Mac
already downloads one pinned package (0060).

## Decision matrix

| Criterion | Shared pinned downloader | Bundle every model | iOS-only downloader |
| --- | --- | --- | --- |
| One tap to a better model | 🟢 Yes. | 🟢 Already there. | 🟢 Yes. |
| App size | 🟢 +0 MB. | 🔴 +1.1 GB. | 🟢 +0 MB. |
| One implementation of fetch, pins, and verification | 🟢 Both apps. | 🟢 No fetch. | 🔴 Two copies to drift. |
| Network exposure | 🟡 HTTPS to pinned Hugging Face commits, on tap only. | 🟢 None. | 🟡 Same, twice. |

## Decision

`Sources/hardware_controller_model_download` holds the catalog, the HTTPS-only
fetcher, and the assembler that verifies each file's pinned size and SHA-256,
then writes the notice and manifest. The Mac installs the result into its single
store; Voice Input admits it through its Rust-validated installer as publisher
verified, then selects it.

Voice Input offers Whisper Base English (85 MB), Whisper Small English (270 MB),
and Parakeet TDT 0.6B v3 (741 MB, the Mac default) beside the bundled Whisper
Tiny English. Downloads start only from an explicit tap, carry no cookies,
cache, or credentials, refuse non-HTTPS redirects, and never send audio or text.
Import from Files remains for packages made on a Mac.

The fetcher is the only network code in Voice Input; only the containing app
links it, never the keyboard or widgets.

## Consequences

- `scripts/check_conventions.sh` allows network APIs only in the fetcher and the
  Ollama adapter; `scripts/check_ios_local_only.sh` fails if anything but the
  app links the download module; `scripts/build_ios_device.sh` fails if an
  extension contains it.
- Updating a pin is a reviewed change to `asr_model_catalog.swift`; tests check
  every entry is HTTPS, commit-pinned, and fully digested.
