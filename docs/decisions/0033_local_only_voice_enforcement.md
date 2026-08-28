# 0033 — Reject remote-capable Voice providers before invocation

## Status

Accepted and implemented for macOS M9.

## Context

The shipped formatting implementations are in-process Apple Foundation Models
and fixed numeric-loopback Ollama. Their concrete types make the current build
local, but the shared provider protocol did not require locality evidence. A
future adapter could therefore receive transcript or context before an
orchestrator discovered that it could use a remote endpoint. M9 also requires
honest degradation when formatting or ASR is unavailable.

## Decision

- Require every `TranscriptRefining` adapter to declare immutable provider
  identity and one locality: `inProcess`, `fixedLoopback`, or `remoteCapable`.
- Admit only in-process and fixed-loopback adapters in local-only mode. Reject a
  remote-capable adapter before readiness, preparation, refinement, release, or
  shutdown invokes it. Do not treat lack of connectivity as an input to local
  Voice behavior.
- Validate the adapter's declared provider identity at routing and its returned
  identity after generation. Fail closed on either mismatch.
- Keep Apple Foundation Models in-process. Keep Ollama on
  `http://127.0.0.1:11434` with the existing proxy, redirect, cache, digest, and
  cloud-tag guards.
- Preserve the three-second formatting deadline and deterministic Edited
  fallback. Fallback still requires the captured target lease to pass before
  one insertion.
- When ASR fails after microphone buffers were captured, finalize the CAF,
  store empty or partial truthful text evidence, mark delivery not attempted,
  and perform no target mutation. Explicit user cancellation still discards its
  owned artifact.

## Consequences

- Adding an API-backed provider later requires an explicit product decision and
  a separate mode; implementing the protocol alone cannot enable content
  transfer in local-only mode.
- A prohibited adapter receives no lifecycle call, so it cannot use readiness
  as an implicit network probe. Local provider behavior does not branch on
  external network state.
- ASR failure remains visible and recoverable without falsely reporting a
  delivery attempt. A failure before the first audio buffer cannot create a
  playable artifact.
- The portable provider facade must preserve the same fail-closed capability
  contract when it replaces the Swift baseline.

## Evidence

Core policy tests admit only in-process and fixed-loopback locality. Router
tests prove normal lifecycle routing and zero invocations for a remote-capable
adapter. A production-controller test routes a remote-capable formatter through
the real router, delivers deterministic fallback once, and stores playable CAF
audio without invoking the adapter. A real CAF/SQLite failure test terminates
ASR after capture and verifies empty text stages, delivery not attempted, zero
formatter and target calls, and playable retained audio. Existing provider-
failure, timeout, late-output, validation, target-lease, and Ollama transport
tests cover the remaining M9 branches. The complete host corpus passes 475 tests
in 71 suites.
