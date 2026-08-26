# Voice critical user journeys

**Status:** Accepted behavior contract; macOS M1 and M2 are implemented. The
authority is
[`0029_local_voice_platform_expansion.md`](decisions/0029_local_voice_platform_expansion.md).

## Purpose

These CUJs define observable behavior before implementation. Tests exercise a
public Voice-session facade with real domain behavior and fake system boundaries;
they do not assert private call sequences or replace the engine with mocks.

Implementation proceeds one vertical slice at a time:

1. select the next approved CUJ behavior;
2. add one failing test at the lowest level that proves it;
3. implement the minimum complete path;
4. run all green tests;
5. refactor only while green; and
6. add the next behavior.

## Shared observable contract

CUJ tests observe stable outcomes rather than implementation types:

| Observation       | Required evidence                                                                              |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| Capture ownership | Exactly one session ID, confirmed start time, visible state, and terminal stop/cancel/failure. |
| Transcript        | Ordered timed Raw spans plus explicit replacements; no duplicate stable ranges.                |
| Spoken edits      | Typed operations and deterministic Edited transcript.                                          |
| Formatting        | Style revision, structured blocks, evidence references, validation result, and Raw fallback.   |
| Delivery          | Target identity/capability snapshot, one attempted rendering, and typed outcome.               |
| History           | Searchable session record independent of delivery success.                                     |
| Audio             | Final artifact or explicit absence/expiry/recovery reason, byte count, duration, and digest.   |
| Provider          | Capability, locality, model identity/digest, and stage metrics.                                |
| Privacy           | No content crosses a remote-capable boundary in local-only mode.                               |

Every workflow must be idempotent under duplicated stop, platform callback, and
delivery-completion events. Tests use a monotonic fake clock for ordering and a
wall clock only for displayed dates.

## Test ladder

| Level               | Scope                                                                                                | Required environment                                                         |
| ------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Contract            | Voice engine, repository, retention, spoken edits, validation, and renderer through public behavior  | Deterministic audio fixtures, temporary storage, fake clock/target/providers |
| Adapter integration | App Group, SQLite/files, audio conversion, platform delivery, model package validation               | macOS/iOS test host and sanitized fixtures                                   |
| System UI           | Global chord, real focused fields, iOS keyboard switching, permissions, backgrounding, Live Activity | Signed Mac or physical iPhone; simulator only where behavior is equivalent   |
| Performance/quality | Audio corpus through production model packages                                                       | Named device tiers with cold/warm and thermal metadata                       |

Mocks are limited to system boundaries: microphone/audio route, clock, filesystem
faults, target field, OS lifecycle, remote/network detector, and model runtime.
Real repositories use temporary directories; real model adapters use a small
sanitized corpus in integration/performance suites.

## E2E selection and change policy

The E2E suite proves only the complete paths whose risk cannot be established
cheaply below the UI/system boundary:

| Platform | Stable E2E spine |
| --- | --- |
| macOS | Hold-to-insert-and-store, latch, focus-change recovery, retention/crash recovery, and offline/model fallback. |
| iOS | Onboarding/typing fallback, warm keyboard capture-to-insertion, cold/suspended activation, interruption/stale service, and offline retention. |

Contract tests cover deterministic state, formatting, retention, recovery, and
privacy combinations. Adapter integration tests cover real persistence, FFI,
App Group, audio, and delivery boundaries. Do not duplicate every combination
as E2E.

E2E tests use accessibility identifiers and user-visible outcomes, not screen
coordinates, incidental view hierarchy, private call order, exact generative
prose, or arbitrary sleeps. Model tests use protected-token and semantic
invariants plus bounded quality/performance metrics. A behavior may change when
one focused PR updates the CUJ, test, implementation, and rationale while
preserving equivalent safety coverage.

## macOS journeys

### M1 — Hold to dictate and recover

**Given** a nonsecure focused text field, microphone/Accessibility permission, a
ready local ASR provider, Natural Style, and enabled History.

**When** the user holds the configured exact chord, says a short phrase, and
releases it.

**Then** capture starts on key-down; provisional text may update; release stops
capture; local ASR creates timed Raw text; formatting validates; Delivered text
is inserted exactly once; and searchable History contains the audio and every
final text stage. If insertion fails, the same History item remains copyable and
retryable.

**First tracer:** a fixture saying “send the revised plan tomorrow” produces one
session, one validated document, one delivery attempt, and one playable artifact
without any network-capable provider receiving content.

### M2 — Latch a long prompt

Two short chord presses within the configured interval latch one session without
delaying the first PCM frame. The user may read and speak across pauses. The next
valid double press stops once. Key repeat, an unmatched release, or a third press
does not create another session. Sleep and lost key-up terminate through the
same recovery state.

**Current evidence:** the independent, opt-in exact Voice chord begins Local AI
Dictation on its first key-down. A long release finishes; two short presses
latch; the next two short presses finish. Pure-state, command-controller,
Carbon-boundary, preference-migration, and runtime tests cover immediate begin,
decision timeout, repeats, unmatched release, interruption, registration
conflict, and transactional replacement. Sleep and shortcut replacement cancel
before Carbon synthesizes a release.

### M3 — Format for purpose

The same Raw transcript can be rendered as Casual Message, Formal, Technical,
Natural, or Verbatim without retranscription. Dictated ordinal structure becomes
validated list blocks. A single-line target receives a safe plain-text rendering;
a multiline target preserves list and paragraph structure. Protected names,
commands, URLs, code tokens, and Dictionary spellings remain unchanged.

### M4 — Backtrack explicitly

“Scratch that,” “delete that sentence,” “new paragraph,” list boundaries, and
“literal” produce typed, replayable operations. An ambiguous command remains
literal text. A destructive command cannot remove stable text outside its
defined range. The Raw transcript remains inspectable.

### M5 — Preserve ownership when the target changes

If focus, caret ownership, secure status, or target process changes after capture
begins, automatic insertion is withheld. Capture and local finalization finish,
History records the reason, and the user can copy or explicitly retry. The app
never submits the target or types into the replacement field.

### M6 — Browse and reuse History

The user searches Raw, Formatted, Delivered, or corrected text; opens a result;
plays from a timed span; sees source, Style, and model evidence; corrects without
mutating earlier stages; and independently retranscribes, reformats, exports,
pins, or deletes the session. Re-running a stage creates a new result linked to
the same immutable audio.

### M7 — Bound storage without surprise

When age, byte, or artifact-count quota is exceeded, cleanup skips active, pinned,
and sole recovery artifacts; removes oldest unpinned audio to the low-water mark;
retains transcript metadata; and records an Audio-expired reason. Derived cache
eviction does not change History. `Unlimited`, zero retained audio, low-disk
cleanup, corrupt sizes, and concurrent finalization have explicit results.

### M8 — Recover from interruption and crash

A crash or process kill during capture leaves at most one partial artifact.
Startup reconciles it into a recoverable session or removes it under the partial
retention rule. Corrupt SQLite state, an orphan audio file, full disk, audio-route
loss, and model cancellation do not block app launch or lose unrelated sessions.

### M9 — Remain local and degrade honestly

Airplane/no-network state does not change successful local behavior. A remote-
capable provider is rejected before content transfer. When formatting is
unavailable or misses its deadline, validated Raw/Edited text is delivered under
the declared fallback policy. When ASR is unavailable, audio remains recoverable
and the target is not modified.

### M10 — Share one session behavior across triggers

A physical Control, Hold chord, latch chord, and in-app record button invoke the
same Voice-session state and History contract. Trigger-specific momentary/toggle
semantics remain adapters; none changes ASR, formatting, retention, or delivery
meaning.

## iOS journeys

### I1 — Onboard locally

The containing app explains local processing and History retention, requests
microphone permission, validates an installed/imported Model package, guides the
user through adding the custom keyboard, and explains Full Access only when
needed for App Group voice coordination. Denial leaves a usable app/keyboard
with exact recovery instructions. No permission prompt originates in the
keyboard extension.

### I2 — Dictate from a warm custom keyboard

**Given** the custom keyboard is visible in an editable nonsecure field and the
containing app can own capture.

**When** the user taps mic, speaks, and taps stop.

**Then** the keyboard waits for confirmed Capture-owner state before showing
recording; the containing app records and runs local ASR/formatting; the keyboard
reflects bounded status; final text is inserted once through
`textDocumentProxy`; and the containing app stores History. No audio is captured
by the extension.

### I3 — Start when the containing app is cold or suspended

The mic action follows the approved documented activation path. If iOS transfers
the user to the containing app, the app clearly confirms capture and tells the
user to return manually; capture may continue only with the required system
indicator/Live Activity. If activation is unavailable, the keyboard presents a
single accurate recovery action and does not show false recording state.

Production implementation of this CUJ requires Gate K0 evidence from a physical
device and current App Review rules. That evidence gate does not stop unrelated
macOS, iOS containing-app, engine, or keyboard work. The journey may not be
weakened into an undocumented launch mechanism.

### I4 — Type without Full Access

Without Full Access, QWERTY typing, deletion, shift, return, space, and the globe
key remain functional. Mic is visibly unavailable with concise setup guidance.
No text, audio, or model operation crosses the unavailable shared-container
boundary.

### I5 — Respect unsupported fields

Secure fields receive the system keyboard. Phone-pad, numeric, one-time-code,
banking, managed-device, and custom host fields follow declared capabilities.
The keyboard never starts capture where insertion or privacy cannot be assured;
it reports unsupported state without retaining target context.

### I6 — Choose a Style without target identity

The keyboard exposes a compact Style selector and remembers the explicit
keyboard/surface default. It does not infer the host application's identity.
Casual, Formal, Technical, Natural, and Verbatim outputs pass the same shared
formatting fixtures as macOS.

### I7 — Survive interruption and background transitions

Incoming calls, Siri, audio-route changes, lock, background expiration, low power,
thermal pressure, and another app taking the microphone produce explicit state.
Live Activity/system recording indication matches Capture ownership. A partial
session remains recoverable; automatic resume never occurs after privacy-
sensitive interruptions without an approved rule.

### I8 — Detect a stale service

If the containing app is killed, upgraded, or no longer publishing a valid
heartbeat, the keyboard stops showing active state, never queues unbounded audio
commands, and offers one restart action. Duplicate or late App Group messages
cannot insert text twice or revive a completed session.

### I9 — Recover failed insertion

If the host field disappears, rejects insertion, or changes during finalization,
the transcript remains in containing-app History. The keyboard offers bounded
retry/copy behavior only for the same confirmed session and target state. A late
completion from an earlier session never overwrites a newer field.

### I10 — Remain offline and within storage limits

Airplane mode completes keyboard and in-app capture with local models. iOS
applies its age/byte quota, pinning, partial recovery, Data Protection, and low-
disk rules without blocking capture. Installed active models are not silently
evicted as History cache.

### I11 — Capture without an active keyboard

An approved App Intent, Action button, Control Center control, Siri phrase, or
in-app button starts a visibly owned Voice session. Lock/background behavior
uses the required Live Activity and finishes into History. Delivery is explicit
copy/share or a later keyboard retrieval; it never guesses a target field.

## Quality and performance fixtures

The shared corpus must include:

- clean, accented, quiet, noisy, fast, and interrupted speech;
- names, company terms, Git, Bash, paths, URLs, identifiers, and code tokens;
- fillers, immediate restatements, literal command phrases, and ambiguous edits;
- paragraphs, numbered/bulleted lists, short messages, and long AI prompts;
- silence, clipped audio, corrupt files, unsupported codecs, and hour-scale input;
- English first plus each language claimed by the selected Model package.

Each published run records WER, proper-noun recall, command precision/recall,
list accuracy, semantic-addition rejection, first partial, Raw finalization,
formatted delivery, real-time factor, peak memory, energy per audio minute,
audio drops, installed bytes, p50/p95/p99/max, sample count, device, OS, thermal
state, and model digest.

## Accepted start conditions

The user accepted on 2026-08-25:

1. M1 as the first tracer and the listed CUJ priority;
2. the observable contract and deterministic Raw fallback;
3. macOS 90-day/2-GiB/5,000-artifact and iOS
   90-day/1-GiB/2,000-artifact audio defaults;
4. 24-hour retention for failed but recoverable partial artifacts;
5. Gate K0 and an honest cold-start/app-switch experience; and
6. benchmark-selected deployment floors and Model packages.

These choices do not approve release promotion or `dev` → `main`. Model,
signed-device, and App Review findings are implementation evidence, not new
preference questions.
