# Hardware Controller

Hardware Controller is a native macOS app that turns a VEC Infinity 3 USB foot
controller into low-latency Actions. Each Control can run Local Dictation,
Local AI Dictation, an exact keyboard shortcut, or No Action using Hold or
Toggle behavior.

All configuration and speech content stay on the Mac. Local AI Dictation uses
Apple's on-device model or a fixed-loopback Ollama service; it never uses cloud
inference.

## Quick start

Requirements: Apple silicon, macOS 15 or later, and Xcode 26 or a compatible
Swift 6 toolchain. Contributors also need rustup; the repository pins Rust 1.98.

```bash
git clone https://github.com/MarcusJRLee/hardware_controller.git
cd hardware_controller
swift run HardwareController --demo
```

Demo mode is deterministic and requires no foot controller, Apple signing
identity, or privacy permission.

## Choose a path

| Goal | Start here | Additional requirement |
| --- | --- | --- |
| Explore the app | `swift run HardwareController --demo` | None |
| Contribute | `scripts/check.sh` | Xcode 26 or compatible Swift 6 toolchain |
| Verify only the portable core | `scripts/check_rust.sh` | rustup and a C17 compiler |
| Use real hardware | [Signed hardware build](#signed-hardware-build) | Apple Development identity and supported Device |
| Install as a nondeveloper | [Public distribution](docs/public_distribution.md) | Notarized public release; not yet available |

## Verify a change

Run the same formatting, build, test, and release-script checks as GitHub:

```bash
scripts/check.sh
```

See the [contributor guide](docs/contributor_guide.md) for source ownership,
test placement, Driver additions, and opt-in system checks.

## Signed hardware build

For a signed local build, create ignored private settings once:

```bash
cp .env.example .env.local
# Replace both placeholders in .env.local with your own signing values.
set -a
source .env.local
set +a
```

Build an app intended for `/Applications` only with that Apple Development
identity:

```bash
security find-identity -v -p codesigning
scripts/build_app.sh
codesign --verify --deep --strict --verbose=2 \
  "dist/Hardware Controller.app"
codesign -dv --verbose=4 "dist/Hardware Controller.app" 2>&1 \
  | grep -E '^Authority='
codesign -dv --verbose=4 "dist/Hardware Controller.app" 2>&1 \
  | grep -E "^TeamIdentifier=${HC_EXPECTED_TEAM_ID}$"
```

Never commit `.env.local`. Quit the running app before replacing the single
canonical `/Applications/Hardware Controller.app`, then launch that exact
bundle. Preserve its marketing version and build number during routine local
iterations. Never install an ad-hoc-signed build.

The application identifier is `com.longdevity.hardwarecontroller`. Profiles
and preferences use only its matching Application Support directory. The
pre-public identity transition is complete, so the public snapshot contains no
predecessor personal namespace. macOS may require Accessibility, Microphone,
Speech Recognition, and Launch at Login authorization again when the signed
application identity changes.

## Product identity

Signal Bridge is the provisional public mark: three generic control nodes on a
near-black surface, joined by one low-latency signal path with an active amber
center. The menu-bar template uses the same three-node geometry. Neither mark
copies a supported Device or manufacturer branding. The source raster is
[`packaging/app_icon_source.png`](packaging/app_icon_source.png).

A source change or version number is not release approval. Do not run
`scripts/build_release.sh`, create a DMG, tag, GitHub Release, or release record
without explicit approval for that exact version. The intentionally retained
accepted-artifact evidence is in
[release validation](docs/release_validation.md).

## First use

1. Open the canonical Applications copy.
2. Allow Accessibility and Microphone when requested. macOS 15–25 also
   requests Speech Recognition.
3. Connect the VEC Infinity 3 and confirm each physical Control visibly changes
   state without producing a pointer click.
4. Configure each Control under **Controller** or its Profile's Device setup.
5. Focus an editable field, hold or toggle the Control, and speak.

The center Control defaults to Local Dictation in Hold mode. Left and right
default to No Action. Any configured Control may receive an opt-in exact
keyboard fallback for use while its Device is disconnected.

To dictate without a Device, open **General → Voice capture shortcut**, record
an exact chord with at least two modifiers, then hold it while speaking. Two
short presses latch capture; the next two finish. The chord uses Local AI
Dictation and is disabled until you configure it.

See the [user guide](docs/user_guide.md) for Profiles, target behavior,
recovery, and troubleshooting.

Voice History repairs app-owned partial, orphan, and interrupted-expiration
audio at startup before applying storage limits. Recovered audio is marked,
playable, and locally retranscribable without invented text; unpinned recovery
audio expires after 24 hours while its History row remains searchable.

## Dictation Actions

| Action | Result | Model dependency |
| --- | --- | --- |
| Local Dictation | Reversible live text where safe, otherwise guarded final text. | Apple on-device speech recognition. |
| Local AI Dictation | One corrected and automatically formatted result after release. | Apple speech plus Apple On-Device or local Ollama refinement. |

Both Actions reuse the same microphone, recognition, target, permission, and
delivery boundaries, but retain separate controllers and settings. One
process-wide coordinator prevents simultaneous microphone ownership. Local AI
model warm-up begins while the user speaks and never blocks the HID-to-Action
path.

Local AI Dictation removes fillers, resolves clear self-corrections, corrects
supported recognition errors, and applies the selected Natural, Casual
Message, Formal, Technical, or Verbatim Style. It creates validated paragraph
and list blocks, then preserves or flattens structure for the target. It
also applies exact spoken commands such as **scratch that**, **delete that
sentence**, **new paragraph**, and numbered-list boundaries before formatting;
say **literal** immediately before a command phrase to keep the phrase. It
validates protected numbers, URLs, email addresses, paths, code-like tokens,
quotations, and dictionary terms. A provider error, invalid output, or
three-second deadline delivers the deterministic Edited transcript once when
the captured target is still safe.

### Apple On-Device

Apple On-Device refinement requires macOS 26, Apple Intelligence enabled, a
supported locale, and installed model assets. Select it under
**General → Local AI Dictation**, refresh status, then test the provider. The
app uses `SystemLanguageModel` locally and does not enable Private Cloud
Compute.

### Ollama

Install and start Ollama separately, then install the recommended model:

```bash
ollama pull qwen3.5:4b
```

Choose **Ollama**, select the installed model, refresh status, and run **Test
Selected Provider**. The app connects only to
`http://127.0.0.1:11434`, rejects redirects and proxy routing, excludes cloud
model tags, and pins the selected local digest. The validated recommendation is
`qwen3.5:4b` with digest:

```text
2a654d98e6fba55d452b7043684e9b57a947e393bbffa62485a7aac05ee4eefd
```

The measured model file is 3.39 GB and its reference resident allocation is
5.74 GB, above the original 4 GB target. Model choice and measurements are in
[Local AI model evaluation](docs/local_ai_model_evaluation.md).

Five-minute retention is the default. **Until app quits** is ownership-aware:
the app unloads a model it started when settings change or the process exits,
but preserves a model that another local Ollama client already had running.

## Privacy and safety

- Local Dictation remains memory-only. Local AI Dictation records one local CAF
  plus immutable Raw, Edited, Formatted, Delivered, and corrected results under
  the app's Application Support directory. **History** can search, inspect,
  replay, correct, retranscribe, reformat, retry, export, pin, and delete those
  sessions. **General → Voice History storage** independently caps audio age,
  total bytes, and recording count; defaults are 90 days, 2 GiB, or 5,000
  recordings, whichever is reached first. `Unlimited` and no-retained-audio
  choices are explicit. Cleanup keeps transcripts searchable and protects
  active, pinned, and sole recovery audio.
- Nearby context, prompts, and model payloads remain memory-only. Speech content
  is never written to logs.
- Apple speech recognition is required to run on-device.
- Ollama traffic is restricted to fixed numeric loopback; no user content is
  sent to a remote host.
- Nearby text is off by default. When enabled, the app reads at most a bounded
  caret window from an approved multiline, nonsecure target for the current
  session.
- The app never reads browser URLs, terminal contents, screenshots, whole
  documents, the pasteboard, or the global keyboard stream.
- Focus and caret ownership are revalidated before delivery. Secure fields are
  rejected.

## What ships

- Exact-signature, exclusive IOKit HID input on a user-interactive serial queue.
- Independent per-Control Bindings, Hold/Toggle semantics, exact keyboard
  fallbacks scoped to the active Profile, and an independent opt-in hold/latch
  Voice chord.
- `SpeechAnalyzer` on macOS 26+ and on-device-required
  `SFSpeechRecognizer` on macOS 15–25.
- Adaptive Accessibility and guarded foreground text delivery for native,
  browser, and validated terminal targets.
- Apple Foundation Models and optional local Ollama refinement behind one typed
  provider contract.
- A dependency-free Rust retention policy and versioned caller-owned C ABI,
  checked against the current Swift policy through one shared CUJ fixture.
- Atomic, schema-versioned local Profiles and application preferences with
  explicit migration, corruption recovery, and forward-schema protection.
- A native Controller, History, Profiles, and General shell with Dock and
  menu-bar presence, searchable local Voice evidence, direct permission
  recovery, and transient final-only transcript HUD.
- No accounts, analytics, telemetry, cloud APIs, remote storage, or third-party
  linked runtime dependencies.

## Opt-in system verification

These checks require the named local resource or foreground target:

```bash
HC_RUN_MICROPHONE_INTEGRATION=1 swift test \
  --filter capturesARealAuthorizedMicrophoneBuffer

HC_RUN_MICROPHONE_INTEGRATION=1 swift test \
  --filter explicitRealMicrophonePreservesTheSystemDefault

HC_RUN_MICROPHONE_ROUTE_INTEGRATION=1 swift test \
  --filter changesTheRealDefaultInputWithoutCrashing

say -v Samantha -o .build/local_transcription_test.aiff \
  "Hardware Controller local transcription test."
HC_SPEECH_AUDIO_FILE="$PWD/.build/local_transcription_test.aiff" \
  swift test --filter modernBackendRepeatedlyTranscribesLocalAudio

HC_RUN_TEXT_INSERTION_INTEGRATION=1 swift test \
  --filter insertsTextIntoTheFocusedRealTextField

HC_RUN_LOCAL_AI_MODEL_EVALUATION=1 swift test \
  --filter LocalAIModelEvaluationTest
HC_RUN_LOCAL_AI_END_TO_END_BENCHMARK=1 swift test \
  --filter measuresWarmReleaseToInsertionWithTheRecommendedModel
```

The web, terminal, foreground-event, and complete speech-to-field commands are
documented in [release validation](docs/release_validation.md).

## Documentation

| Path | Authority |
| --- | --- |
| [License](LICENSE) | Apache License 2.0 terms. |
| [Notice](NOTICE) | Marcus John Rice Lee attribution retained by Apache redistributors. |
| [Contributing](CONTRIBUTING.md) | Development workflow, privacy rules, and inbound Apache licensing. |
| [Contributor guide](docs/contributor_guide.md) | Local paths, source ownership, test placement, and Driver work. |
| [Branding](BRANDING.md) | Canonical-project and modified-build identification. |
| [User guide](docs/user_guide.md) | Installation, setup, use, and troubleshooting. |
| [Product brief](docs/product_brief.md) | Product scope, domain language, and acceptance stories. |
| [Voice platform design](docs/voice_platform_design.md) | Accepted local Voice roadmap for the existing macOS app and iOS. |
| [Voice CUJs](docs/voice_cujs.md) | Accepted test-first macOS and iOS behavior contract. |
| [Voice implementation goal](docs/voice_implementation_goal_prompt.md) | Copy-paste autonomous execution prompt and definition of done. |
| [Game plan](docs/game_plan.md) | Current quality gates and remaining evidence. |
| [Public distribution](docs/public_distribution.md) | Gated Developer ID, notarization, and free-DMG runbook. |
| [Public repository migration](docs/public_repository_migration.md) | Completed clean-history replacement record and GitHub controls. |
| [Architecture](docs/architecture.md) | Component, concurrency, persistence, privacy, and failure boundaries. |
| [Implementation context](CONTEXT.md) | Stable names for deep implementation modules. |
| [UX specification](docs/ux_spec.md) | Current visual and accessibility behavior. |
| [Infinity 3 evidence](docs/hardware/infinity_3.md) | Device protocol evidence and physical checks. |
| [Decisions](docs/decisions/) | Durable product and architecture decisions. |

The project is open source under the [Apache License 2.0](LICENSE). Copyright
remains with Marcus John Rice Lee; intentional contributions are accepted
under Apache 2.0 as described in [`CONTRIBUTING.md`](CONTRIBUTING.md). See
[`NOTICE`](NOTICE) for attribution and [`BRANDING.md`](BRANDING.md) for
canonical-project identification. Longdevity LLC formation and ownership
transfer remain future work. Source licensing does not approve or publish a
binary release.
