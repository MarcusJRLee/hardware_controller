# Contributing

Issues and pull requests are welcome. For a substantial behavior or
architecture change, open an issue first so scope and evidence are agreed.

```bash
brew install mise    # Once per Mac, then add `eval "$(mise activate zsh --shims)"` to ~/.zprofile.
mise trust && mise install && lefthook install   # Once per clone: kit tools, git hooks.
scripts/run_demo.sh   # Explore without a pedal, signing, or permissions.
scripts/check.sh      # Required before every PR; same as the Verify CI job.
scripts/check_ios.sh  # When touching apps/ios or shared Voice code.
```

The scripts build the Rust archive first. Before a bare `swift build` or
opening the package in Xcode, run `scripts/build_rust_ffi.sh` once.

## Pull requests

- One reason to change per PR, on a branch from `main`, squash-merged.
- Colocated `FILENAME_test.EXT` for every file with behavioral logic.
  `scripts/check_conventions.sh` enforces it for Swift; a Swift file without
  logic needs a reasoned line in `Tests/untested_sources.txt`. The kit's
  `test_ownership.py` covers every other language; exempt a file by path in
  `.mjrlee_repo_setup/test_exemptions.toml`. `check_conventions.sh` also
  rejects dashed paths, non-Foundation imports in the domain, and network APIs outside
  the Ollama adapter. `.swift-format` rejects force unwraps, `try!`, and
  implicitly unwrapped optionals.
- Format with `scripts/swift_format.sh format --in-place --recursive Sources Tests`.
  It runs the swift-format pinned in `tools/swift_format/`, not Xcode's, so
  local and CI lint agree; bump it there, never per machine.
- Update docs and journey proofs ([voice_cujs.md](voice_cujs.md)) in the
  same PR; `scripts/check_docs.sh` fails on broken links or missing tests.
- Update the topic's [decision record](decisions/) when a durable choice changes.
- Never change version metadata or create release artifacts without explicit
  approval for that exact version.

Required checks: `Verify` (`scripts/check.sh`, then an ad-hoc packaged build
smoke-launched by `scripts/smoke_app.sh`) and `CodeQL`. The `iOS` job runs
`scripts/check_ios.sh`.

To prove a change in the running app, follow the
[verify skill](../.claude/skills/verify/SKILL.md).

## CI lanes

macOS runners are scarce, so `scripts/classify_changes.sh` runs on Ubuntu and
starts only the lanes a change needs ([Builds and workflow](decisions/builds_and_workflow.md)):

| Lane | Runs when | Runner | Budget |
| --- | --- | --- | --- |
| Verify, fast | Only prose or repo-kit files changed (`*.md`, `docs/`, `.claude/`, `.mjrlee_repo_setup/`, `.lefthook/`, `.codex/`, `lefthook.yml`) | Ubuntu | 15 min |
| Verify, full | Anything else changed | macOS | 15 min |
| iOS | `apps/ios`, shared Core, FFI, Rust, ASR or iOS scripts | macOS | 25 min |
| CodeQL (macos / ios) | That platform's Swift or shared sources | macOS | 35 min |
| CodeQL (actions) | Always | Ubuntu | 10 min |
| Tool cache | `main` changes the formatter pin; weekly | macOS | 20 min |

PRs read caches saved on `main` but not each other's, so **Tool cache** saves
the pinned swift-format there; without it every PR rebuilds it (~8 min).
Workflow edits run every lane. `scripts/check_workflows.sh` fails on a job
without a timeout, over budget, or on macOS without `needs: changes` or push
`paths:`. The weekly
**CI health** workflow fails when a job's p50 passes 70% of its budget; run
`scripts/ci_durations.sh` to see p50, max, and queue time.

## Landing

`main` requires up-to-date branches, so each merge restarts the next PR's
lanes. Land one PR at a time: update its branch from `main`, wait for required
checks, squash-merge, then move to the next.

- CI runs on `pull_request` only, so pushing a branch costs nothing; open the
  PR once its base has landed.
- Cancel runs on a stacked PR until its base lands.

## Toolchain compatibility

CI uses the `macos-26` image's default Xcode (26.6, Swift 6.2, iOS 26.5 SDK as
of 2026-11), which may be older than yours. These pass on newer Xcode and fail
in CI:

| Pattern | Why it fails on Xcode 26 | Write instead |
| --- | --- | --- |
| `AVAudioConverter.convert` input block capturing a mutable flag or buffer | The block is `@Sendable`. | A `Sendable` one-shot input object owning the buffer and a `Mutex` flag (`OneShotAudioInput` in `microphone_capture.swift`). |
| Typed `throws` inside `withUnsafeBufferPointer`, `withCString`, or `map` | Those are `rethrows`, which erases the typed error. | Return `Result` from the closure and call `.get()` outside, or use a loop. |

## Source map

| Path | Owns |
| --- | --- |
| `Sources/HardwareControllerCore/` | Hardware-independent domain, Profiles, migrations, transcript policy. |
| `Sources/HardwareControllerMac/` | IOKit, Accessibility, audio, speech, refinement, persistence adapters. |
| `Sources/HardwareControllerAudioBoundary/` | Objective-C exception boundary around AVFAudio. |
| `Sources/HardwareControllerApp/` | App lifecycle, runtime, SwiftUI presentation. |
| `Sources/hardware_controller_voice_ffi/`, `Sources/voice_ffi_bridge/` | Typed Swift over the Rust C ABI. |
| `Sources/voice_asr_bridge/`, `Sources/voice_asr_runtime/` | C bridge over transcribe.cpp and its typed Swift owner. |
| `Sources/hardware_controller_asr_*` | macOS ASR XPC service, its kit, and the app-to-service protocol. |
| `Sources/hardware_controller_model_download/` | Pinned speech-model catalog, HTTPS fetcher, and verifying assembler for both apps. |
| `tools/app_icons/` | Code that renders both app icons. |
| `crates/` | Portable Rust: `voice_core`, `voice_models`, `voice_archive`, `voice_ffi`. |
| `apps/ios/voice_input/` | iOS app, keyboard, widgets, and their tests. |
| `schemas/` | Versioned Model-package and archive contracts. |
| `Tests/cuj/` | Fixtures shared by Rust, Swift, and C. |
| `Tests/hardware_controller_test_support/` | `ManualClock` and `waitUntil`, shared by macOS and iOS tests. |
| `packaging/` | Info.plist, entitlements, icon source. |
| `.mjrlee_repo_setup/`, `.lefthook/`, `.codex/` | Shared repo kit: agent and git hooks, gates, roadmap tool; edit the kit, not these copies. |

## Tests

- Core logic → `HardwareControllerCoreTests`; macOS adapters →
  `HardwareControllerMacTests`; runtime and presentation →
  `HardwareControllerAppTests`.
- Default tests never prompt for permissions, need a pedal or microphone, or
  touch the network. Inject clocks, stores, and system boundaries.
- Default tests never sleep or bound real time: Swift Testing runs them in
  parallel, so a loaded runner stretches both. Drive deadlines with
  `ManualClock` (`waitForSleeper(dueWithin:)`, then `advance(by:)`) and await
  events with `waitUntil`, both in `Tests/hardware_controller_test_support/`.
  Only opt-in suites and SQLite busy-wait tests use real time, with a comment
  saying why.
- Portable policy changes update the shared fixture, Rust test, Swift test,
  header, and decision together. Unsafe code stays in `voice_ffi`.

## Opt-in system checks

```bash
HC_RUN_MICROPHONE_INTEGRATION=1 swift test --filter capturesARealAuthorizedMicrophoneBuffer
HC_RUN_MICROPHONE_ROUTE_INTEGRATION=1 swift test --filter changesTheRealDefaultInputWithoutCrashing
HC_RUN_TEXT_INSERTION_INTEGRATION=1 swift test --filter insertsTextIntoTheFocusedRealTextField
HC_RUN_LOCAL_AI_MODEL_EVALUATION=1 swift test --filter LocalAIModelEvaluationTest
HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK=1 swift test --filter measuresWarmReleaseToInsertionWithTheRecommendedModel
HC_RUN_IOS_ASR_PERFORMANCE=1 scripts/check_voice_asr_bridge.sh
TEST_RUNNER_HC_RUN_KEYCHAIN_BENCHMARK=1 scripts/check_ios.sh
```

Real speech through the macOS recognizer:

```bash
say -v Samantha -o .build/speech.aiff "Hardware Controller local transcription test."
HC_SPEECH_AUDIO_FILE="$PWD/.build/speech.aiff" swift test --filter modernBackendRepeatedlyTranscribesLocalAudio
```

## Adding a Driver

Add a narrow signature, a report decoder emitting stable Control identities,
layout metadata, and sanitized fixtures for press, release, repeats,
simultaneous Controls, reconnect, and disconnect-while-active. Keep changed
firmware rejected until a physical unit proves it. Report callback-to-dispatch
p50, p95, p99, max, and sample count.

## Privacy

Never commit credentials, configuration, transcripts, logs, serial numbers,
unsanitized HID captures, signing identities, or Team identifiers. Report
vulnerabilities through [SECURITY.md](SECURITY.md).

## License

Contributions are licensed under [Apache 2.0](../LICENSE) (Section 5). You keep
your copyright; no CLA is required.
