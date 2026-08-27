# 0037: Portable Model-package validation

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:**
  [`0029_local_voice_platform_expansion.md`](0029_local_voice_platform_expansion.md)

## Context

Portable ASR and formatting runtimes require multiple model, tokenizer,
configuration, and notice files. An internal file digest proves consistency
with its manifest; it does not authenticate a manifest supplied by the same
untrusted download. Model code and model weights also have separate licenses.

The leading runtime candidates already expose broad native surfaces:

- [sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/) documents fully local
  inference across macOS, iOS, Android, Windows, and Linux.
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) exposes a C API and
  Apple, Android, Windows, and Linux support.
- [RustCrypto SHA-2](https://docs.rs/sha2/latest/sha2/) supplies a pure-Rust,
  dual MIT/Apache-2.0 SHA-256 implementation with optimized and portable
  backends.

No runtime or model is selected by this decision. It defines the admission
boundary required before measured candidates can be installed or invoked.

## Decision matrix

| Criterion | Trust archive name | Self-declared file hashes | Pinned manifest plus file hashes |
| --- | ---: | ---: | ---: |
| Detect payload corruption | 1 | 5 | 5 |
| Authenticate approved downloads | 1 | 1 | 5 |
| Support explicit manual imports | 3 | 5 | 5 |
| Bound archive/path attacks | 1 | 3 | 5 |
| Preserve model/license provenance | 1 | 4 | 5 |
| **Total** | **7** | **18** | **25** |

Use an optionally pinned exact manifest digest plus mandatory per-file digests.

## Contract

- A Model package is a private staging directory containing
  `manifest.json` and only its declared payload. Schema
  [`voice_model_package_v1.schema.json`](../../schemas/voice_model_package_v1.schema.json)
  defines the publisher format; the Rust validator is the acceptance authority.
- V1 carries package identity/version, display name, runtime family, one stage,
  stage-compatible capabilities, languages, SPDX expression, notice path,
  HTTPS source, memory metadata, file roles, exact bytes, and SHA-256 digests.
- Defaults cap the manifest at 1 MiB, one package at 8 GiB, and payload count at
  4,096. Every limit is caller-configurable. Empty payloads and arithmetic
  overflow fail closed.
- Paths must be portable canonical relative paths. Reject absolute, traversal,
  empty-segment, reserved-manifest, backslash, colon, control-character, and
  overlong paths. Reject every symbolic link, undeclared file, missing file,
  size mismatch, and digest mismatch.
- Approved downloads supply an out-of-band expected manifest SHA-256. A manual
  import may omit it, but later UI must label its publisher origin unverified.
  Complete verification always returns the exact manifest digest.
- Keep staging private from concurrent mutation through validation and atomic
  installation. Archive extraction is a platform installer responsibility and
  must apply independent compressed/uncompressed limits before this boundary.
- License metadata and an in-package notice are mandatory. Validation preserves
  evidence; it does not make a legal compatibility determination.
- `voice_models` owns verification. `voice_ffi` exposes one synchronous V1 C
  call with typed status classes and caller-owned UTF-8 buffers. It retains no
  path, buffer, callback, handle, file, allocator, or thread across return.
- The verifier may use serde/serde_json and RustCrypto SHA-2. No model runtime,
  network client, downloaded weight, or app runtime dependency is added here.

## Consequences

macOS, iOS, Android, and later desktop adapters can admit identical package
bytes without reproducing trust, path, license, or limit policy. The shipped
macOS app remains on its current Apple/Ollama providers until a benchmarked
runtime package passes separate quality, latency, memory, energy, and license
gates.

## Evidence

- `schemas/voice_model_package_v1.schema.json`
- `Tests/cuj/voice_model_package_v1/valid/`
- `crates/voice_models/src/model_package_test.rs`
- `crates/voice_models/src/model_package_file_system_test.rs`
- `crates/voice_ffi/src/ffi_test.rs`
- `Tests/voice_ffi/retention_smoke.c`
