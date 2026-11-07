# Hardware Controller

A native macOS app that turns a VEC Infinity 3 foot pedal into low-latency
Actions (Local Dictation, Local AI Dictation, keyboard shortcuts), plus the iOS
**Voice Input** app and keyboard. Everything runs on-device: no accounts,
telemetry, or cloud inference.

## Quick start

Requires Apple silicon, macOS 15+, Xcode 26+, and rustup (Rust is pinned).

```bash
git clone https://github.com/MarcusJRLee/hardware_controller.git
cd hardware_controller
scripts/run_demo.sh   # Deterministic demo; no pedal, signing, or permissions.
scripts/check.sh      # Everything the Verify CI job runs.
```

## Commands

| Goal | Command | Needs |
| --- | --- | --- |
| Run the demo | `scripts/run_demo.sh` | — |
| Verify macOS, Rust, and the C bridge | `scripts/check.sh` | — |
| Verify only Rust and the C ABI | `scripts/check_rust.sh` | — |
| Verify the iOS app | `scripts/check_ios.sh` | XcodeGen, simulator, `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` |
| Install the signed Mac app | `scripts/install_app.sh` | `.env.local` signing values |
| Smoke-launch a built app | `scripts/smoke_app.sh <bundle> [--demo \| --installed]` | — |
| Prove the installed speech service | `scripts/check_speech_engine.sh [APP]` (run by every install) | A signed app |
| Install the iOS app on a phone | `scripts/install_ios.sh` | Unlocked iPhone in Developer Mode, `.env.local` |
| Prepare an extra iOS model package | `scripts/prepare_ios_asr_model_package.sh <dir>` | Network during preparation only |
| Benchmark ASR models | `scripts/benchmark_asr.sh [--model m.gguf] [--manifest m.tsv]` | — |

Signing values live in the ignored `.env.local` (copy `.env.example`); a
`.worktrees/` checkout without one reads the main checkout's.
`install_app.sh` is the only install path: it refuses ad-hoc or expired
identities, verifies Team, entitlements, hardened runtime, Apple-only
libraries, and unchanged version metadata, replaces the one
`/Applications/Hardware Controller.app`, re-verifies it, and proves the
installed bundle launches and stays up.

`benchmark_asr.sh` prints p50/p95/p99/max latency, median real-time factor, and
word error rate. Without `--manifest` it synthesizes speech with `say`, which
measures cost, not quality; for quality, list your own clips as
`id<TAB>clip.wav<TAB>reference` in an ignored TSV.

Opt-in system checks (real microphone, speech, focused fields, local models)
are listed in [CONTRIBUTING.md](docs/CONTRIBUTING.md#opt-in-system-checks).

## Style

Calm, tactile, precise: a studio utility, not a settings form. Neutral
surfaces, system typography, no decorative borders, and one strong action per
workflow. Color appears only for active state, required attention, or errors.
The icons, Center Signal, are rounded capsules on graphite with only the
center lit amber: three pedals for Hardware Controller, a voice waveform for
Voice Input (`swift tools/app_icons/render_app_icons.swift`). Details:
[UX specification](docs/ux_spec.md).

## Documentation

| Path | What it holds |
| --- | --- |
| [User guide](docs/user_guide.md) | Setup, daily use, privacy, troubleshooting. |
| [Product brief](docs/product_brief.md) | Scope, canonical language, approved boundaries. |
| [Architecture](docs/architecture.md) | Components, data flow, concurrency, persistence, security. |
| [Voice journeys](docs/voice_cujs.md) | Every critical user journey and the test that proves it. |
| [Game plan](docs/game_plan.md) | Quality gates, open evidence, risks. |
| [UX specification](docs/ux_spec.md) | Visual and accessibility contract. |
| [Contributing](docs/CONTRIBUTING.md) | Workflow, source map, test placement, Drivers. |
| [Decisions](docs/decisions/) | One current decision record per topic. |
| [Infinity 3 evidence](docs/hardware/infinity_3.md) | Device protocol evidence. |
| [Public distribution](docs/public_distribution.md) | Gated Developer ID and notarization runbook. |
| [Local AI model evaluation](docs/local_ai_model_evaluation.md) | Model measurements behind the recommendation. |

A version number is not release approval: no release script, DMG, tag, or
GitHub Release without explicit approval for that exact version.

Licensed under [Apache 2.0](LICENSE); copyright Marcus John Rice Lee
([NOTICE](NOTICE), [BRANDING](docs/branding.md)).
