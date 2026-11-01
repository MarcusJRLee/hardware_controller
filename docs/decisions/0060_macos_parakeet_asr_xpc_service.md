# Decision 0060: macOS Parakeet ASR in an XPC service

**Status:** Proposed; awaiting approval before implementation. Amends the
in-process rule in [0029](0029_local_voice_platform_expansion.md) and the
isolation consequence in [0055](0055_transcribe_cpp_asr_runtime.md).

## Context

macOS transcribes with Apple `DictationTranscriber`
(`.progressiveLongDictation`) on macOS 26 and the legacy on-device recognizer
on macOS 15–25. Parakeet TDT 0.6B v3 already runs on iOS through the pinned
transcribe.cpp runtime. The macOS app does not link that runtime today.

The Device hot path shares the app process. ggml reports internal errors with
`abort()`, and a Metal fault or hang inside a decode would take every Device,
active Action, and capture with it. Apple's recognizer does not have this
exposure: during measurement its inference ran in
`Speech.framework/XPCServices/localspeechrecognition.xpc` (204 MB RSS, 135%
CPU) while the calling process stayed at 21 MB peak footprint.

Measurements, Apple M5 Max, `scripts/benchmark_asr.sh` synthetic corpus (five
clips, 2–84 s), 2026-11-01, with other workloads running. Parakeet and Whisper
use the production bridge with speech detection and one warm-up pass. Apple
uses the app's exact transcriber configuration in a scratch harness.

| Provider | Measures | Samples | p50 | p95 | p99 | Max | WER | Peak footprint |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple, audio fed in real time | Release to final text | 15 | 245 ms | 995 ms | 995 ms | 995 ms | 2.7% | 17 MB + system service |
| Apple, audio fed at once | Start to final text | 35 | 581 ms | 6,959 ms | 7,536 ms | 7,536 ms | 2.7% | 21 MB + system service |
| Parakeet v3 Q8_0, Metal | Whole recording after release | 35 | 72 ms | 563 ms | 582 ms | 582 ms | 0.0% | 379 MB |
| Parakeet v3 Q8_0, CPU only | Whole recording after release | 35 | 324 ms | 2,709 ms | 2,750 ms | 2,750 ms | 0.0% | 700 MB |
| Whisper tiny.en Q8_0, Metal | Whole recording after release | 35 | 48 ms | 403 ms | 418 ms | 418 ms | 0.8% | 251 MB |

Parakeet's p95 is the 84-second clip decoded in one pass after release. With
pause-cut live decoding ([0056](0056_ios_live_pause_cut_decoding.md)), release
waits only for the last chunk (a 2.3-second clip decodes in 39 ms); on macOS
that is a hypothesis until implemented. Synthetic speech measures cost, not
real dictation quality.

| Criterion | Apple only (today) | Parakeet in-process | Parakeet in an XPC service | Moonshine streaming in XPC |
| --- | --- | --- | --- | --- |
| Release latency, measured | p50 245 ms, p95 995 ms | p50 72 ms, p95 563 ms | Same plus IPC (hypothesis: under 10 ms) | Not measured; the bridge has no streaming API |
| WER, synthetic | 2.7% | 0.0% | 0.0% | Not measured |
| macOS 15–25 | Legacy recognizer | Supported (runtime minimum macOS 13) | Supported | Supported |
| Kernel abort, fault, or hang | Isolated by the system | Kills the app and the Device hot path | Kills only the service; app falls back | Same as XPC |
| Memory after use | System-managed | App grows about 380 MB until ggml frees | Service exit returns everything | Same as XPC |
| Third-party code in the app binary | None | ggml linked into the app | Only the embedded service links it | Same as XPC |
| Model setup | System asset | Explicit 485–740 MB package | Same | Same, different package |
| Cost | None | Small | Medium: target, bundle, signing, protocol, supervisor | Large: streaming bridge first |
| Decision | Stays the default | Rejected | Selected, opt-in | Deferred until measured |

## Decision

- Add an opt-in Parakeet provider on macOS. Apple stays the default on every
  macOS version; nothing changes for a user who does not select Parakeet.
- Run it in `HardwareControllerASRService.xpc`, embedded in
  `Contents/XPCServices`, launched on demand by launchd. Same Team signature,
  hardened runtime, and no network entitlement. Only the service links the
  pinned `CTranscribe.framework`; release binary policy allows it there alone,
  matched by its pinned digest.
- XPC is local Mach IPC with no socket, port, or listener. 0029's rule becomes:
  inference stays on-device, in-process or in an app-embedded XPC service; no
  local REST daemon or network listener.
- One versioned `NSXPCConnection` protocol: load a Model package, transcribe
  16 kHz mono float samples with the 0055 request (language, vocabulary,
  speech detection), and unload. Results and failures are typed; text never
  enters logs.
- An app-side actor supervises the connection, following Handy's engine
  supervisor:
  - Interruption or invalidation returns a typed failure, and the session
    retranscribes the retained recording with Apple's recognizer. The
    recording is the durable capture, so no audio is lost.
  - A crash during a Metal decode reloads the service CPU-only. A second crash
    in the same app run disables Parakeet until relaunch and says so in
    settings.
  - A decode exceeding max(2 s, 0.25 × audio duration) invalidates the
    connection, which kills the service, and falls back.
  - Five idle minutes unloads the service so its memory returns to the system.
- Model packages reuse the V1 schema and Rust's `voice_asr_model_resolve_v2`.
  The app resolves the package; the service revalidates digests immediately
  before load. v1 offers explicit import of a prepared package only; an in-app
  download from a pinned source is a later, separate change.
- Local AI settings gain a speech recognition choice: Apple (default) or
  Parakeet, with the installed package and its state.
- History records the ASR provider and Model package identity and digest per
  Voice session through an explicit migration. Existing sessions read as
  Apple.

## Gates

| Gate | Contract |
| --- | --- |
| Hot path | The HID soak budget holds while the service decodes, crashes, and relaunches. |
| Release latency | p95 ≤ 1 s on the reference Mac, matching Apple's measured tail. |
| IPC | Round trip p99 ≤ 10 ms for 30 s of audio. |
| Recovery | Killing the service mid-decode yields Apple text from the same recording, with no lost audio and no duplicate delivery. |
| Memory | Service exit after idle returns its footprint; the app's footprint does not grow. |

## Delivery

Each slice ships with its tests and docs: the service, protocol, and
supervisor with whole-recording transcription behind a disabled setting; then
settings and History provenance; then pause-cut live decoding; then a
Moonshine streaming measurement.

## Consequences

- The app bundle gains a 13 MB runtime inside the service. Packaging, signing,
  smoke, and release verification cover two executables.
- Parakeet users import a 485–740 MB package before first use.
- iOS is unchanged; it cannot spawn processes and keeps in-process inference.
