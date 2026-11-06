# Local-only boundary

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0033, and the offline-check part of 0049

## Context

Every shipped provider is local, but a protocol that does not require
locality would let a future adapter receive transcript or context before
anything noticed it could reach a remote endpoint. The iOS app must make its
offline boundary mechanically checkable, with one deliberate exception: model
downloads the owner asked for.

## Decision

**Providers**

- Every `TranscriptRefining` adapter declares an immutable provider identity
  and one locality: `inProcess`, `fixedLoopback`, or `remoteCapable`.
- Local-only mode admits only in-process and fixed-loopback adapters and rejects
  a remote-capable one before readiness, preparation, refinement, release, or
  shutdown touches it. Connectivity is never an input to Voice behavior.
- Validate the declared identity at routing and the returned identity after
  generation; fail closed on a mismatch.
- Apple Foundation Models stay in-process. Ollama stays on
  `http://127.0.0.1:11434` with proxy, redirect, cache, digest, and cloud-tag
  guards.
- When ASR fails after audio was captured, keep the playable recording, store
  truthful empty or partial text, mark delivery not attempted, and touch no
  target. Explicit cancellation still discards its artifact.

**Network code**

- The only network code is the Ollama adapter (macOS) and the pinned model
  fetcher in `Sources/hardware_controller_model_download` (both apps), which
  runs only on an explicit Download tap ([model_packages](model_packages.md)).
  No audio, text, or identifier is ever sent.
- `scripts/check_conventions.sh` allows network APIs in those two files only.
- `scripts/check_ios_local_only.sh` runs in every iOS check. It rejects other
  network clients, Network.framework, transport-security settings, push,
  associated domains, iCloud, and networking capabilities, and fails if
  anything but the containing app links the download module.
  `scripts/build_ios_device.sh` fails if an extension contains the fetcher.

## Consequences

- An API-backed provider needs its own product decision and mode; implementing
  the protocol cannot enable content transfer.
- A prohibited adapter gets no lifecycle call, so readiness cannot be a hidden
  network probe.
- Physical airplane-mode capture remains part of signed-iPhone verification.
