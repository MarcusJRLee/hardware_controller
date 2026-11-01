# Decision 0055: transcribe.cpp ASR runtime

**Status:** Accepted; supersedes the runtime selection in
[0042](0042_ios_whisper_file_asr.md)

## Context

Decision 0042 pinned whisper.cpp `b4938` for iOS completed-file ASR. That
runtime runs only Whisper, so Parakeet, Moonshine streaming, and Silero speech
detection each needed a second runtime. Two widely used local dictation apps,
Hex and Handy, both moved to transcribe.cpp: one ggml runtime with a C API for
Whisper, Parakeet, Moonshine, Nemotron, Qwen3-ASR, and Silero VAD. Its official
`v0.4.1` release ships one XCFramework for iOS, the iOS simulator, and macOS.

Hex is written in Rust, but its inference kernel is transcribe.cpp. A
Rust-native kernel such as Candle is not yet a measured option for Parakeet
on Metal. Rust validation plus a narrow C bridge over a mature C++ kernel is
the shape [0029](0029_local_voice_platform_expansion.md) already permits.

| Criterion | transcribe.cpp 0.4.1 | whisper.cpp b4938 | sherpa-onnx | FluidAudio |
| --- | --- | --- | --- | --- |
| Model families | Whisper, Parakeet, Moonshine, Nemotron, Qwen3-ASR | Whisper only | Many, through ONNX | Parakeet and CoreML models |
| Speech detection | Silero in the same library | Separate | Built in | Built in |
| Platforms | iOS, macOS, Android, Windows, Linux | Same | Same | Apple only |
| Distribution | One official XCFramework, 10 MB archive | One XCFramework | Library plus ONNX Runtime | Swift package |
| Vocabulary hints | Feature-gated per family; Whisper today | Initial prompt only | Hotwords for transducers | CTC rescoring |
| Decision | Selected | Retired | Streaming comparator | Apple-only comparator |

Reference Mac (Apple M5 Max) measurements through the production bridge, using
the synthetic corpus from `scripts/benchmark_asr.sh` with speech detection, one
warm-up pass, and seven measured passes (35 samples):

| Model | Load | p50 | p95 | Max | Median RTF | WER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Whisper tiny.en Q8_0 | 3,145 ms first launch | 35 ms | 313 ms | 317 ms | 0.0040 | 0.8% |
| Parakeet TDT 0.6B v3 Q8_0 | 123 ms | 52 ms | 364 ms | 384 ms | 0.0048 | 0.0% |
| Parakeet TDT 0.6B v3 Q4_K_M | 112 ms | 54 ms | 386 ms | 386 ms | 0.0049 | 0.8% |

Synthetic speech measures runtime cost, not real dictation quality. Real
quality claims require a private corpus of human-referenced recordings; see
the README.

## Decision

- Pin the official transcribe.cpp `v0.4.1` XCFramework archive and every
  consumed binary, header, and license digest. Fetch it into ignored build
  storage; never commit runtime binaries.
- Replace `voice_whisper_bridge` with the runtime-neutral `voice_asr_bridge`.
  It owns one model, one session, and an optional speech-detection session.
  Callers pass a typed request with language, up to 64 vocabulary terms, and a
  speech-detection flag.
- When speech detection is requested, decode only detected speech. Merge speech
  into chunks of at most 28 seconds, cut at pauses, pad chunks shorter than
  1.5 seconds with trailing silence, and keep absolute segment times. No
  detected speech returns `NO_SPEECH`. A decode that stopped early returns
  `INCOMPLETE_TRANSCRIPT`. Neither delivers partial text.
- Apply vocabulary only when the loaded model declares the vocabulary feature.
  An unsupported model ignores the terms without failing.
- Add the `transcribe_cpp` runtime and an optional `speech_detection` file role
  to the V1 Model-package schema. Rust revalidates the package, resolves exactly
  one model, and resolves at most one speech-detection payload.
- Replace `voice_asr_model_resolve_v1` with `voice_asr_model_resolve_v2`, which
  returns both paths. V1 resolved only the retired runtime, and its only consumer
  is built from this repository.
- `whisper_cpp` packages still validate, but the resolver rejects them as an
  unsupported runtime. The starter package becomes
  `com.longdevity.asr.whisper_tiny_en` with Whisper tiny.en Q8_0 and Silero
  v6.2, prepared by `scripts/prepare_ios_asr_model_package.sh`.
- Disable runtime logging in release builds. Development builds keep runtime
  diagnostics on standard error.
- Keep inference in-process. Out-of-process isolation is a separate decision
  that matters only once macOS hosts a native kernel next to the Device hot path.

## Verification

`scripts/check_voice_asr_bridge.sh` links the real macOS slice on every check.
It covers argument and reserved-byte rejection, the buffer-too-small contract,
the vocabulary capability, silence returning `NO_SPEECH`, transcription with
and without speech detection, and a 37-second clip with three utterances that
must split into at least two chunks with absolute, ordered segment times.
`scripts/benchmark_asr.sh` uses the same bridge. It reports p50, p95, p99,
maximum, median RTF, and WER. Running it found that runtime segments lack their
separating whitespace. The bridge now owns that space, and the long-form test
rejects fused words.

## Consequences

- An installed whisper.cpp package must be replaced by importing the new
  starter package. The app reports the incompatible runtime instead of loading
  it.
- Parakeet TDT v3 is available to iOS through the same package contract. On
  device it is a memory and latency question that physical evidence must settle
  before it becomes the recommended package.
- Live chunked decoding during capture needs a sample tap in place of the
  current file recorder. That change is recorded separately, not hidden in this
  runtime swap.
