# Speech recognition runtime

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0042, 0055, 0056, 0060

## Context

Apple's recognizer is the main accuracy complaint on macOS. whisper.cpp ran
only Whisper. transcribe.cpp is one ggml runtime with a C API for Whisper,
Parakeet, Moonshine, Nemotron, Qwen3-ASR, and Silero VAD, used by Hex and
Handy. On macOS the Device hot path shares the app process, and ggml reports
internal errors with `abort()`.

| Criterion        | transcribe.cpp 0.4.1 | whisper.cpp | sherpa-onnx | FluidAudio |
| ---------------- | -------------------- | ----------- | ----------- | ---------- |
| Model families   | 🟢 Five, plus VAD.   | 🟠 Whisper only. | 🟢 Many via ONNX. | 🟡 Parakeet, CoreML. |
| Platforms        | 🟢 Apple, Android, Windows, Linux. | 🟢 Same. | 🟢 Same. | 🔴 Apple only. |
| Distribution     | 🟢 One XCFramework, 10 MB. | 🟢 One XCFramework. | 🟠 Plus ONNX Runtime. | 🟡 Swift package. |

| Provider (M5 Max, synthetic corpus) | Measures | Samples | p50 | p95 | p99 | Max | WER | Peak footprint |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple, real-time feed | Release to final | 15 | 245 ms | 995 ms | 995 ms | 995 ms | 2.7% | 17 MB + service |
| Parakeet v3 Q8_0, Metal | Whole recording | 35 | 72 ms | 563 ms | 582 ms | 582 ms | 0.0% | 379 MB |
| Whisper tiny.en Q8_0, Metal | Whole recording | 35 | 48 ms | 403 ms | 418 ms | 418 ms | 0.8% | 251 MB |

| Where the macOS kernel runs   | In the app process | App-embedded XPC service |
| ----------------------------- | ------------------ | ------------------------ |
| Abort, Metal fault, or hang   | 🔴 Kills the app and hot path. | 🟢 Kills the service; app falls back. |
| Memory after use              | 🟠 App keeps ~380 MB. | 🟢 Returned on exit. |
| Added latency                 | 🟢 None.           | 🟢 Measured p99 2.2 ms at 84 s. |

Synthetic speech measures cost, not real dictation quality.

## Decision

**Runtime and bridge**

- Pin the official transcribe.cpp `v0.4.1` XCFramework and every consumed
  binary, header, and license digest; fetch into ignored storage.
- `voice_asr_bridge` owns one model, one session, and an optional
  speech-detection session. A typed request carries language, up to 64
  vocabulary terms, and a speech-detection flag. Vocabulary applies only when
  the model declares the feature.
- With speech detection, decode only speech, merged into chunks of at most
  28 s cut at pauses, padding chunks under 1.5 s, with absolute segment times.
  No speech returns `NO_SPEECH`; an early stop returns `INCOMPLETE_TRANSCRIPT`;
  neither delivers partial text. The bridge owns inter-segment spaces.
- Rust revalidates the package immediately before every load and resolves
  exactly one `model` and at most one `speech_detection` file
  (`voice_asr_model_resolve_v2`). `whisper_cpp` packages still validate but are
  refused as an unsupported runtime.
- Runtime logging is off in release builds.

**iOS**

- Inference runs in-process in the containing app only; the keyboard and
  widgets never touch audio, model paths, or runtime symbols.
- Live pause-cut decoding: an `AVAudioEngine` tap beside the recorder feeds
  16 kHz mono audio to `voice_asr_live_*`. Cut at a ~600 ms pause once a chunk
  holds 10 s, or at the longest pause before 28 s. Stop drains the tap; the live
  transcript is used only if it covers the recorded file within 0.5 s for the
  selected model. Any failure falls back to transcribing the file, which stays
  the durable evidence. Packages without speech detection decode after Stop.

**macOS**

- transcribe.cpp is the default engine and Parakeet TDT 0.6B v3 the default
  package. Apple's recognizer runs only when explicitly selected or after a
  service failure.
- A missing setup step never silently degrades quality: with no valid package,
  Dictation is refused with a prompt to download or explicitly switch to Apple,
  which asks for confirmation naming it less accurate.
- The kernel runs in `HardwareControllerASRService.xpc` in
  `Contents/XPCServices`, launched on demand, same Team, hardened runtime, no
  network entitlement. Only the service links `CTranscribe.framework`.
- One versioned `NSXPCConnection` protocol loads a package, transcribes 16 kHz
  mono samples (sent as raw bytes) with the request above, and unloads. Text
  never enters logs.
- An app-side supervisor handles failure: interruption retranscribes the
  retained recording with Apple; a Metal crash reloads CPU-only; a second crash
  uses Apple until relaunch; a decode over max(2 s, 0.25 × duration) kills the
  service; five idle minutes unload it. Each fallback is shown in the session
  indicator and recorded in History.
- History records the engine and package identity and digest per session;
  older sessions read as Apple.
- Dictionary replacements apply to every engine; Parakeet ignores recognition
  hints, and the Dictionary view says so.

**Gates**

| Gate            | Contract | Status |
| --------------- | -------- | ------ |
| Hot path        | HID soak budget holds while the service decodes, crashes, relaunches. | Soak during a live crash not yet measured. |
| Release latency | p95 ≤ 1 s on the reference Mac. | 84 s clip p95 408 ms. |
| IPC             | Round trip p99 ≤ 10 ms for 30 s of audio. | p99 2.2 ms at 84 s. |
| Recovery        | Killing the service mid-decode yields Apple text from the same recording. | SIGKILL returns `interrupted`; reload matches. |
| Memory          | Service exit returns its footprint. | Not yet measured. |
| Real speech     | Parakeet WER on the owner's recordings no worse than Apple's. | Open; a regression reopens this. |

## Consequences

- macOS Dictation needs a 741 MB download or an explicit choice of Apple first;
  the bundle gains a 13 MB runtime inside the service, and signing and release
  checks cover two executables.
- Every signed install runs `scripts/check_speech_engine.sh`; ad-hoc builds
  cannot load the service, so CI covers it with unit and protocol tests.
- With transcribe.cpp, macOS 15–25 need no Speech Recognition permission.
- Open gates and next work are roadmap items: `macos_live_decoding`,
  `speech_service_gates`, `real_speech_comparison`, `moonshine_streaming_comparison`,
  and `ios_physical_evidence`.
