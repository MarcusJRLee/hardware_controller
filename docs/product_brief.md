# Product brief

## Product promise

Hardware Controller makes a physical Control feel like a native extension of
the Mac: connect it, choose what it does, and receive an immediate,
predictable response in the active app.

The primary workflow is hands-free Dictation:

1. Put the text cursor in an app.
2. Hold the center Control.
3. Speak.
4. Release to finish.

Toggle mode starts on one press and finishes on the next. Users choose Local
Dictation for live recognized text or Local AI Dictation for one corrected and
automatically formatted result.

## Product principles

1. **Immediate:** input handling and speech/model latency are measured against
   explicit percentile budgets.
2. **Quiet:** the app stays out of the way until status or configuration is
   needed.
3. **Legible:** Device, permission, Profile, provider, and Action state are
   obvious.
4. **Safe:** disconnects, permission loss, invalid model output, and termination
   cannot leave an Action held or mutate the wrong target.
5. **Local:** configuration, speech, context, prompts, and generation remain on
   the Mac; no cloud inference is allowed.
6. **Extensible:** hardware facts stop at the Driver boundary and Local AI
   providers stop at one typed refinement boundary.

## Canonical language

| Term | Meaning |
| --- | --- |
| Device | One connected physical controller. |
| Control | One independently actuated input on a Device. |
| Control event | A timestamped press, release, or value change. |
| Driver | A Device-specific adapter that turns raw input into Control events. |
| Action | Behavior the app can execute. |
| Binding | A Control plus interaction mode mapped to an Action. |
| Profile | A named collection of per-Device Bindings for one work mode. |
| Momentary | Begin on press and end on release. User-facing copy says “Hold.” |
| Toggle | Alternate between begin and end on successive presses. |
| Active Action | An Action that began and has not yet ended. |
| Formatting provider | A local model boundary that converts Edited text evidence into a Formatted document. |
| Raw transcript | Final on-device speech-recognition text before Dictionary replacement, spoken edits, or refinement. |
| Edited transcript | Raw text after deterministic spoken edits and Dictionary replacements. |
| Spoken edit | A typed, source-evidenced deterministic operation applied before formatting. |
| Formatted document | Validated paragraph and list blocks linked to Raw evidence. |
| Delivered text | A target-specific plain-text rendering of the Formatted document. |
| Style | A versioned Natural, Casual Message, Formal, Technical, or Verbatim formatting policy. |
| Voice trigger | An input adapter that begins, finishes, or cancels the same Voice-session workflow without changing its ASR, formatting, delivery, or History meaning. |
| Voice chord | The optional machine-wide exact keyboard shortcut dedicated to Voice capture; it is distinct from a Binding keyboard fallback. |
| Latched capture | A Voice session kept active after two short Voice-chord presses until the next valid double press. |

Use `pedal` only for Infinity-specific UI copy. Domain and reusable UI use
`Control` so future buttons, knobs, switches, and MIDI controls fit without a
rename.

## Current scope

### Device behavior

- Support one or more VEC Infinity 3 Devices through a dedicated Driver.
- Recognize all three Controls, including simultaneous presses.
- Recover from unplug/replug, sleep/wake, relaunch, and disconnect while an
  Action is active.
- Show unsupported Devices without pretending they are configurable.

### Actions

- **No Action**.
- **Local Dictation**, preserving adaptive live/final delivery.
- **Local AI Dictation**, refining final Apple speech text through Apple
  On-Device or fixed-loopback Ollama.
- **Keyboard Shortcut**, including modifiers and ordinary keys.
- Hold and Toggle wherever supported.
- Idempotent end/cancel for every stateful Action on handoff, Device removal,
  Profile replacement, permission loss, sleep, and shutdown.

Only one Dictation Action may own the microphone. Choosing Local AI Dictation
does not modify Local Dictation's behavior, defaults, live composition, or
failure path.

### Local AI behavior

- Warm the selected model after an accepted begin while speech capture starts
  independently.
- Remove fillers and abandoned fragments, resolve clear self-corrections,
  correct supported recognition mistakes, and add punctuation.
- Produce validated paragraph, bullet, or numbered-step blocks, then preserve
  structure for multiline targets or flatten it safely for single-line targets.
- Apply the selected Natural, Casual Message, Formal, Technical, or Verbatim
  Style. Casual Message prefers lowercase sentence starts; Verbatim skips
  generative refinement.
- Accept machine-wide recognition vocabulary, deterministic exact
  replacements, and optional formatting instructions.
- Apply exact `scratch that`, `delete that sentence`, `new paragraph`, `start a
  numbered list`, and `end list` commands before formatting. `literal` preserves
  the immediately following exact command phrase; near-misses remain text.
- Optionally use a bounded caret window from the current nonsecure multiline
  target. Never read browser URLs, terminal contents, whole documents,
  screenshots, the pasteboard, or secure fields.
- Treat transcript and context as untrusted data and require one typed text
  output.
- Preserve protected numbers, URLs, email addresses, paths, code-like tokens,
  quotations, and dictionary values.
- Deliver refined text once, or deterministic Edited text once after provider
  failure, invalid output, or a three-second post-release deadline when target
  ownership remains valid.
- Require an empty captured caret and revalidate target process, secure status,
  focused element, and expected caret before every Local AI mutation. Preserve
  the captured delivery route; never fall through to a replacement adapter.
- Store local audio plus distinct Raw, Edited, Formatted, and Delivered stages
  for later History slices; keep current-session copy actions separate.

### Configuration

- Create, rename, duplicate, delete, edit, and activate Profiles.
- Store independent per-Device-model setups in each Profile.
- Make left, center, and right independently configurable.
- Default center to Local Dictation in Hold mode; default left and right to No
  Action.
- Optionally assign one exact keyboard fallback to a Binding. Suggest `⌃⇧⌘D`
  but never enable it automatically.
- Optionally assign one machine-wide Voice chord under General. Begin on the
  first key-down; release after a hold to finish, or double press to latch and
  double press again to finish. Never enable it automatically.
- Keep Local AI provider, model/digest, retention, Style, context permission,
  Dictionary, and additional instructions machine-wide under General.
- Recommend the measured Qwen 3.5 4B Ollama model while allowing explicitly
  selected installed models to remain labeled unvalidated.
- Persist Profiles and application preferences locally, atomically, and with
  explicit version migrations and forward-schema protection.

### App experience

- A normal foreground Mac app with Dock, application-menu, and menu-bar
  presence.
- One window with Controller, History, Profiles, and General in an
  expanded-by-default native sidebar.
- Searchable local History with immutable result evidence, timed audio,
  correction, retranscription, reformatting, explicit re-delivery, export,
  pinning, and deletion.
- Immediate physical state, active-Profile state, independent Action
  readiness, and direct permission/provider recovery.
- A click-through transcript HUD only while an active target cannot display
  provisional text inline.
- A dedicated Local AI status card for preparing, listening, finalizing,
  refining, validating, delivering, completed, fallback, and failure states.
- No Clean/Structured mode; target-aware formatting is automatic.
- Optional launch at login and app-local microphone selection.

## Acceptance stories

### Local Dictation

Given a focused editable field and a Local Dictation Binding:

- begin starts capture and on-device recognition once;
- duplicate presses do not duplicate starts;
- stable Accessibility fields receive reversible provisional text;
- web, terminal, and other compatibility targets receive guarded final text;
- finish commits once without revising committed text;
- focus or caret changes stop automatic insertion and retain explicit recovery;
- Local AI settings and provider availability have no effect.

### Local AI Dictation

Given a focused editable field and a ready selected provider:

- begin captures the target, starts the shared local speech path, and warms the
  model concurrently;
- provisional recognition appears only in the transient HUD;
- finish obtains one Raw transcript, applies exact replacements and typed spoken
  edits, refines, validates, and inserts one result;
- formatted structure is preserved only for a target that safely supports it;
- provider absence, digest drift, malformed output, overload, or timeout inserts
  deterministic Edited text once if the original target remains valid;
- cancellation, process change, secure-status change, focus change, or caret
  change discards late model output and stores a typed delivery reason;
- raw and refined recovery controls remain distinct.

### Dictation handoff

Given either Dictation Action is active:

- beginning the other cancels the current workflow before the replacement
  begins;
- Profile replacement, microphone selection, permission loss, sleep,
  disconnect, and shutdown clean both workflows idempotently;
- hardware callbacks never wait on speech, model, persistence, or UI work.

### Profiles and keyboard fallback

Given Profiles contain different Device setups:

- the active Profile is persisted before runtime adoption;
- active Actions end before replacement;
- a held input must release and press again under the new Profile;
- exact fallbacks are active only for the active Profile and preserve the
  Binding's Action and Hold/Toggle behavior;
- duplicate, recursive, or unavailable fallback chords produce typed recovery.

### Independent Voice chord

Given a configured Voice chord and ready Local AI Dictation:

- the chord works without a connected Device and never becomes a Binding;
- first key-down begins capture without waiting to decide hold versus latch;
- a held chord finishes on release, while two short presses latch;
- the next valid double press finishes a latched session exactly once;
- repeats and unmatched releases are inert; and
- replacement, sleep, and shutdown cancel active capture before unregistering.

### Permissions and provider readiness

- Missing Accessibility blocks only Actions that require target mutation or
  synthetic input while preserving physical state.
- Missing Microphone blocks both Dictation Actions but not Keyboard Shortcut.
- Missing legacy Speech Recognition permission blocks Dictation on macOS
  15–25.
- An unavailable Apple model or Ollama service/model/digest blocks only Local
  AI Dictation for the selected provider.
- Provider testing uses a fixed sanitized phrase and never starts the
  microphone or reads a target.

## Out of scope

- Cloud sync, accounts, analytics, telemetry, remote control, or remote model
  providers.
- Private Cloud Compute fallback.
- A second speech recognizer, Whisper runtime, or direct-audio language model.
- A shipped mobile, Windows, or Linux app in the current macOS release. iOS is
  an accepted active roadmap; Android, Windows, and Linux remain line of sight.
- Downloaded Driver code or user-authored plug-ins.
- Arbitrary shell commands, scripts, or AppleScript.
- Automatic per-application Profile switching.
- Public App Store submission, payment, licensing, or update infrastructure.

These are current boundaries, not prohibitions on measured future work. Durable
changes require a decision record under [`decisions/`](decisions/).

The accepted local-first Voice program supersedes these boundaries one tested
vertical slice at a time. M1 persists Local AI Dictation audio and distinct
final text stages; M2 adds the independent hold/latch Voice chord; M3 adds
versioned Styles and structured formatting; M4 adds typed replayable spoken
edits; M5 preserves target ownership; M6 adds searchable, reusable History.
Retention enforcement, the portable engine, and iOS remain pending. See
[`0029_local_voice_platform_expansion.md`](decisions/0029_local_voice_platform_expansion.md),
[`voice_platform_design.md`](voice_platform_design.md), and
[`voice_cujs.md`](voice_cujs.md).
