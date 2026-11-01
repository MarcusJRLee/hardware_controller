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
| Build a signed Mac app | `scripts/build_app.sh` | `.env.local` signing values |
| Install the iOS app on a phone | `scripts/install_ios.sh` | Unlocked iPhone in Developer Mode, `.env.local` |
| Prepare the iOS starter model | `scripts/prepare_ios_asr_model_package.sh <dir>` | Network during preparation only |
| Benchmark ASR models | `scripts/benchmark_asr.sh [--model m.gguf] [--manifest m.tsv]` | — |

Signing values live in the ignored `.env.local` (copy `.env.example`). Never
commit it, and never install an ad-hoc-signed build in `/Applications`.

`benchmark_asr.sh` prints p50/p95/p99/max latency, median real-time factor, and
word error rate. Without `--manifest` it synthesizes speech with `say`, which
measures cost, not quality; for quality, list your own clips as
`id<TAB>clip.wav<TAB>reference` in an ignored TSV.

Opt-in system checks (real microphone, speech, focused fields, local models)
are listed in [CONTRIBUTING.md](CONTRIBUTING.md#opt-in-system-checks).

## Style

Calm, tactile, precise: a studio utility, not a settings form. Neutral
surfaces, system typography, no decorative borders, and one strong action per
workflow. Color appears only for active state, required attention, or errors.
The icon, Signal Bridge, is three generic nodes joined by one amber signal
path ([source](packaging/app_icon_source.png)). Details:
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
| [Contributing](CONTRIBUTING.md) | Workflow, source map, test placement, Drivers. |
| [Decisions](docs/decisions/) | Durable, append-only decision records. |
| [Infinity 3 evidence](docs/hardware/infinity_3.md) | Device protocol evidence. |
| [Public distribution](docs/public_distribution.md) | Gated Developer ID and notarization runbook. |
| [Local AI model evaluation](docs/local_ai_model_evaluation.md) | Model measurements behind the recommendation. |

A version number is not release approval: no release script, DMG, tag, or
GitHub Release without explicit approval for that exact version.

Licensed under [Apache 2.0](LICENSE); copyright Marcus John Rice Lee
([NOTICE](NOTICE), [BRANDING](BRANDING.md)).
