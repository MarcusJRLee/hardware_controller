# Hardware Controller

Hardware Controller is a native macOS app that turns a VEC Infinity 3 USB foot
controller into low-latency Actions. Each Control can run Local Dictation,
Local AI Dictation, an exact keyboard shortcut, or No Action using Hold or
Toggle behavior.

All configuration and speech content stay on the Mac. Local AI Dictation uses
Apple's on-device model or a fixed-loopback Ollama service; it never uses cloud
inference.

## Quick start

Requirements: Apple silicon, macOS 15 or later, Xcode 26 or a compatible Swift
6 toolchain, and rustup. The repository pins Rust 1.98.

```bash
git clone https://github.com/MarcusJRLee/hardware_controller.git
cd hardware_controller
scripts/run_demo.sh
```

Demo mode is deterministic and requires no foot controller, Apple signing
identity, or privacy permission.

## Choose a path

| Goal | Start here | Additional requirement |
| --- | --- | --- |
| Explore the app | `scripts/run_demo.sh` | rustup |
| Contribute | `scripts/check.sh` | Xcode 26 or compatible Swift 6 toolchain |
| Verify only the portable core | `scripts/check_rust.sh` | rustup and a C17 compiler |
| Verify the iOS app | `scripts/check_ios.sh` | Xcode 26, XcodeGen, iOS simulator, and Rust iOS targets |
| Install the iOS app | `scripts/install_ios.sh` | Connected unlocked iPhone, Developer Mode, Apple Development identity, and private Team ID |
| Build the iOS app | `scripts/build_ios_device.sh` | Rust iOS targets, Apple Development identity, and private Team ID |
| Prepare the iOS starter model | `scripts/prepare_ios_whisper_model_package.sh /path/to/output` | 130 MB free build space and HTTPS during preparation |
| Use real hardware | [Signed hardware build](#signed-hardware-build) | Apple Development identity and supported Device |
| Install as a nondeveloper | [Public distribution](docs/public_distribution.md) | Notarized public release; not yet available |

## Verify a change

Run the same formatting, build, test, and release-script checks as GitHub:

```bash
scripts/check.sh
```

`scripts/check_ios.sh` additionally rejects network clients and network/cloud
capabilities in iOS product sources before building or testing.

## Install the iOS app

Configure the ignored `.env.local` signing values, connect and unlock an iPhone,
then run:

```bash
scripts/install_ios.sh
```

The command asks which available iPhone and configuration to use, then builds,
installs, and launches Voice Input. **Development** is the default Debug build.
**Local QA** is an optimized Release build that remains Apple Development
signed; it is not an App Store or production release. Automation may use
`--device <identifier-or-name> --config <development|local_qa>`.

See the [contributor guide](docs/contributor_guide.md) for source ownership,
test placement, Driver additions, and opt-in system checks.

The iOS app performs capture and inference locally and has no model-download
path. To exercise its first speech-to-text adapter, prepare the pinned Whisper
Tiny English package on the Mac, move that folder into Files on the iPhone,
then use **Voice Input → Local models → Import Model package → Use for speech to
text**. Runtime/model downloads occur only in repository build preparation;
the installed app does not require a network connection.

The custom keyboard records through the containing app or its Control Center
control; iOS does not permit microphone capture inside a keyboard extension.
After local finalization, the keyboard makes one automatic insertion attempt.
If no field update is confirmed, **Recover…** permits one explicit same-target
retry or an on-device clipboard copy that expires after ten minutes and cannot
cross Universal Clipboard. Any field, session, or process change falls back to
**Voice Input → History**, where completed text remains copyable.

**Voice Input → History → History storage** configures recording age, total
bytes, and count. The defaults are 90 days, 1 GiB, and 2,000 recordings. Pin
important audio to exclude it from automatic cleanup; transcripts remain after
audio expires. Low-disk maintenance restores a 1 GiB free-space reserve without
discarding a committed capture. Installed Model packages use a separate budget
and are removed only by an explicit user action.

For keyboard-free iPhone capture, add **Voice Capture** to Control Center, the
Lock Screen, or the Action button, or use the bundled Siri/Shortcuts start and
stop actions. The containing app records locally and shows a Live Activity with
a stop action. Completed text is saved before it becomes available; copy or
share it from **Voice Input → History**, or retrieve it from the keyboard later.

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

Across macOS and iOS, the interface is restrained and purpose-led: neutral
surfaces, no decorative borders, system typography, and one strong action per
workflow. Color is reserved for state or recovery that cannot be communicated
as clearly through hierarchy and symbols.

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
History can also import a supported local recording, transcribe and format it
on-device, and retain one app-owned copy without changing the original. V1
`.voice_history` archives move immutable transcript/audio evidence between
installations through the Rust verifier linked into the Apple app, then bounded
Swift restore logic. Import never delivers text.

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
sentence**, **new paragraph**, **start a bullet list**, **bullet**, **next
item**, and numbered-list boundaries before formatting;
say **literal** immediately before a command phrase to keep the phrase. It
normalizes conservative grocery, shopping, packing, task, explicit-marker,
and sequential-ordinal list cues before formatting. Typed casing policy can
retain the selected Style, lowercase prose while preserving source-signaled
names, or enforce strict lowercase while protecting operational tokens. The
formatter returns typed paragraph/list blocks; deterministic normalization
restores protected token spelling and list boundaries when Edited text has
confident cues. The same casing and spoken-list rules run on macOS and iOS. It
validates protected numbers, URLs, email addresses, paths, code-like tokens,
quotations, and dictionary terms. A provider error, invalid output, or
three-second deadline delivers the deterministic Edited transcript once when
the captured target is still safe.

**General → Local AI Dictation** names speech-to-text and formatting separately.
Its active-pipeline evidence shows each provider and model, typed output,
validation boundary, and deterministic fallback. History records whether each
formatted result was validated or used the Edited fallback.

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
- A dependency-free Rust retention policy plus bounded, digest-verifying Model-
  package and Voice History archive validators behind one versioned caller-
  owned C ABI.
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

HC_RUN_IOS_ASR_PERFORMANCE=1 scripts/check_voice_whisper_bridge.sh
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
