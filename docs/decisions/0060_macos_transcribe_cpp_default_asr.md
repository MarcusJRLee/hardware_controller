# Decision 0060: transcribe.cpp as the macOS default speech engine

**Status:** Accepted 2026-11-01. The owner added that a missing setup step must
never silently degrade to Apple. Amends the in-process rule in [0029](0029_local_voice_platform_expansion.md) and the
isolation consequence in [0055](0055_transcribe_cpp_asr_runtime.md).

## Context

macOS transcribes with Apple `DictationTranscriber`
(`.progressiveLongDictation`) on macOS 26 and the legacy on-device recognizer
on macOS 15–25. Its accuracy is the main complaint about Dictation. The iOS app
already runs transcribe.cpp, which hosts Parakeet TDT 0.6B v3; the macOS app
does not link that runtime.

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

Where the kernel runs:

| Criterion | In the app process | App-embedded XPC service |
| --- | --- | --- |
| Kernel abort, Metal fault, or hang | Kills the app and the Device hot path | Kills only the service; the app falls back |
| Memory after use | App grows about 380 MB until ggml frees | Service exit returns everything |
| Third-party code in the app binary | ggml linked into the app | Only the service links it |
| Added latency | None | Local IPC (hypothesis: under 10 ms) |
| Decision | Rejected | Selected |

How the default model reaches the Mac (app today: 10 MB):

| Criterion | Apple default (today) | Parakeet, one-click download at onboarding | Bundled Whisper tiny, Parakeet as upgrade | Bundled Parakeet Q4_K_M |
| --- | --- | --- | --- | --- |
| Accuracy | 2.7% synthetic WER; weak in use | 0.0% synthetic | Smallest Whisper; likely weak on real speech (hypothesis) | 0.8% synthetic |
| First launch | Works | Dictation asks for the download first | Works | Works |
| App size | 10 MB | 23 MB; model stored separately | About 70 MB | About 500 MB on every update |
| Dictionary recognition hints | Supported | Not supported by Parakeet yet | Supported | Not supported |
| Model update | System-managed | Replace the package | Tied to app versions | Tied to app versions |
| Decision | Fallback only | Selected | Rejected | Rejected |

Moonshine streaming could cut release latency further, but the bridge has no
streaming API and nothing is measured; it is a later comparison.

## Decision

- transcribe.cpp is the macOS default speech engine and Parakeet TDT 0.6B v3 is
  its default Model package. Apple's recognizer runs only when the user
  explicitly selects it, or after a service failure.
- A missing setup step never silently degrades quality. While Parakeet is the
  selected engine and no valid package is installed, every Dictation start is
  refused with a setup prompt offering the download or an explicit switch to
  Apple. Switching to Apple asks for confirmation that names it the less
  accurate engine, and settings keep a visible note while it is selected.
- A per-session fallback after a service failure is announced in that
  session's indicator and recorded in History.
- Run the kernel in `HardwareControllerASRService.xpc`, embedded in
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
    in the same app run uses Apple until relaunch, and settings and the
    indicator say so.
  - A decode exceeding max(2 s, 0.25 × audio duration) invalidates the
    connection, which kills the service, and falls back.
  - Five idle minutes unloads the service so its memory returns to the system.
- Onboarding and Local AI settings offer one explicit download of the pinned
  Parakeet package from an approved source, as 0029 permits. It shows the size
  before starting, carries no Voice content, and installs only after Rust
  validates identity, digest, license, size, and compatibility. Import of a
  prepared package stays available. The service revalidates digests
  immediately before load.
- Settings show the selected engine, the installed package and its state, and
  whether this run has fallen back to Apple after repeated service crashes.
- Dictionary replacements apply to every engine. Parakeet ignores recognition
  hints until transcribe.cpp supports them for its family; the Dictionary view
  says so while Parakeet is active.
- History records the ASR engine and Model package identity and digest per
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
| Real speech | Parakeet's WER on a private corpus of the owner's recordings is no worse than Apple's; a regression reopens this decision. |

## Delivery

Each slice ships with its tests and docs:

1. Service, protocol, and supervisor with whole-recording transcription and
   Apple fallback.
2. Package download and import, settings, and the default switch.
3. History provenance.
4. Pause-cut live decoding.
5. Moonshine streaming measurement.

## Consequences

- Dictation on macOS needs a 485–740 MB download or an explicit choice of
  Apple before first use.
- The app bundle gains a 13 MB runtime inside the service. Packaging, signing,
  smoke, and release verification cover two executables.
- Names that relied on Apple recognition hints may regress under Parakeet until
  hint support exists; Dictionary replacements still apply.
- macOS 15–25 gain the same engine as macOS 26.
- iOS is unchanged; it cannot spawn processes and keeps in-process inference.
