# Decision 0042: iOS whisper.cpp file ASR

**Status:** Accepted

## Context

Before this decision, iOS Model-package admission was complete but Gate K0
still published a placeholder after capture. The first production adapter must
convert the containing app's 16 kHz mono CAF to timed Raw text locally, remain
replaceable, and avoid linking microphone, model, or runtime code into the
keyboard.

Measured selection used the same pinned `tiny.en` model and 11-second JFK WAV:

| Criterion | whisper.cpp b4938 | sherpa-onnx 1.13.6 | WhisperKit | Candle Whisper |
| --- | --- | --- | --- | --- |
| Initial iOS scope | File ASR with timed segments | Streaming and file ASR | Apple-optimized ASR | Rust-native ASR |
| Runtime surface | One 2.8 MB iOS framework slice | sherpa plus ONNX Runtime | Swift package plus Core ML assets | Rust kernels and model conversion |
| Platform line of sight | iOS, macOS, Android, Windows, Linux | iOS, macOS, Android, Windows, Linux | Apple platforms | Platform/backend dependent |
| Warm reference inference | 0.041 seconds, RTF 0.0038 | Not yet measured on this corpus | Not yet measured on this corpus | Not yet measured on this corpus |
| Integration evidence | Official XCFramework and C API | Official Swift package and C API | Official Swift API | Rust API |
| First-provider decision | Selected | Streaming challenger | Apple comparator | Rust comparator |

The first cold host process spent 7.247 seconds compiling and loading Metal;
the next process loaded in 0.083 seconds. Model prewarming must therefore be an
owned state transition, not hidden inside Stop.

## Decision

- Pin the official whisper.cpp `b4938` XCFramework archive and every consumed
  artifact digest. Fetch it into ignored build storage; do not commit generated
  framework binaries.
- Keep the model separate. The app imports a validated Model package and never
  downloads a model at runtime. A repository script prepares the pinned
  `tiny.en` starter package for manual import.
- Revalidate the selected package, expected manifest digest, inventory, and
  payload digests in Rust immediately before every context use. Resolve exactly
  one `model` role only for `whisper_cpp` + `asr` + `file_asr` packages.
- Put whisper.cpp behind a narrow C bridge with an opaque, exclusively owned
  context, an explicit package-derived ISO language subtag or automatic
  detection, and caller-owned bounded transcript/segment buffers. Swift owns
  CAF conversion, actor isolation, prewarming, and typed UI errors.
- Persist only package ID, version, and manifest digest as the active ASR
  selection. Removing the active package clears that selection. Installed
  active models remain exempt from automatic eviction.
- Link and embed whisper.cpp only in the containing app. The keyboard and
  Control Center extension continue to exchange bounded Keychain state and
  never access audio, model paths, weights, or runtime symbols. Ship the pinned
  upstream MIT notice as a containing-app resource.
- Keep sherpa-onnx as the leading streaming challenger. Promote it only after
  the same corpus and physical-device tiers show a material I2 latency or
  quality advantage.

## Verification

Rust tests reject wrong runtime/stage/capability, ambiguous payloads, wrong
manifest digests, and changed payload bytes. Swift tests cover active selection,
removal, corruption, orchestration, timed-segment decoding, and bounded runtime
results. A real C consumer loads the pinned framework/model, transcribes the
pinned WAV, verifies segment offsets/timestamps, and enforces RTF at most 0.75;
the reference warm CPU run measured RTF 0.0111. Simulator unit/UI tests keep the
no-model path explicit. Signed physical-iPhone latency, thermal, energy, and
microphone-to-keyboard insertion evidence remains a C4 gate.

## Implications

I2 now has real local Raw ASR and model prewarming, but it is not complete until
deterministic edits, optional formatting, History commit, signed-device
app-switching, and one-time keyboard delivery all pass together. The bridge is
file-ASR-only; streaming state requires a separately versioned ownership design.
