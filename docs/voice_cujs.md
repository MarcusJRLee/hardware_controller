# Voice critical user journeys

**Status:** Accepted behavior contract; macOS M1–M15, iOS Gate K0, I1 local
onboarding and Model-package admission, and I2 through local formatting and
History are implemented. The authority is
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
| Formatting        | Style revision, structured blocks, evidence references, validation result, and deterministic Raw/Edited fallback. |
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
| Adapter integration | Shared Keychain, SQLite/files, audio conversion, platform delivery, model package validation         | macOS/iOS test host and sanitized fixtures                                   |
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
shared Keychain, audio, and delivery boundaries. Do not duplicate every combination
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

**Current evidence:** General stores one versioned Natural, Casual Message,
Formal, Technical, or Verbatim Style. The prompt carries the selected Style as
typed data; Verbatim bypasses model preparation and generation. Validated model
text becomes evidence-backed paragraph, unordered-list, or ordered-list blocks;
Verbatim uses an opaque evidence-backed block so its text is not interpreted.
Sequential ordinal cues normalize to an ordered-list block even when a safe
model response retains them as prose. One deterministic renderer preserves
those blocks for multiline targets and
flattens them for single-line targets. SQLite stores the structured document
beside distinct Raw, Edited, Formatted, and Delivered text, and migrates M1/M2
databases without rewriting their rows.

### M4 — Backtrack explicitly

“Scratch that,” “delete that sentence,” “new paragraph,” list boundaries, and
“literal” produce typed, replayable operations. An ambiguous command remains
literal text. A destructive command cannot remove stable text outside its
defined range. The Raw transcript remains inspectable.

**Current evidence:** the deterministic Swift engine recognizes only the five
exact command phrases and one exact `literal` prefix. Operations record source
UTF-8 evidence, the affected Edited suffix, and a typed replacement. Clause and
sentence deletion stop at stable punctuation or an active list-item marker;
`new paragraph` begins the next item while a numbered list is active. Revision,
command evidence, canonical ranges, ordering, replay, and stored-result
corruption are rejected during SQLite write and read. Commands run against Raw
before Dictionary output can synthesize one. The formatter receives Edited text, provider fallback delivers
the same Edited text, and a fully scratched session retains Raw/audio evidence
without generation or insertion. Near-misses and inapplicable commands remain
literal. Deterministic engine, replay, controller, fallback, empty-result, JSON,
SQLite migration, and corruption tests cover the journey.

### M5 — Preserve ownership when the target changes

If focus, caret ownership, secure status, or target process changes after capture
begins, automatic insertion is withheld. Capture and local finalization finish,
History records the reason, and the user can copy or explicitly retry. The app
never submits the target or types into the replacement field.

**Current evidence:** Local AI captures an empty selected range and preserves
the target's delivery route. Delivery rechecks process, secure status, focused
element, and expected caret before each mutation; a failed lease performs no
later mutation. The copyable Formatted/Edited result, audio, human-readable
failure, and stable typed reason remain in the stored session. Deterministic
policy, route-preservation, per-chunk writer, controller, SQLite migration, and
database-reopen tests cover this guard. M6 adds explicit re-delivery as a new
result linked to the immutable session.

### M6 — Browse and reuse History

The user searches Raw, Formatted, Delivered, or corrected text; opens a result;
plays from a timed span; sees source, Style, and model evidence; corrects without
mutating earlier stages; and independently retranscribes, reformats, exports,
pins, or deletes the session. Re-running a stage creates a new result linked to
the same immutable audio.

**Current evidence:** History is a fourth native destination backed by actor-
owned SQLite. It searches every result stage, exposes provenance and bounded
timed spans, appends correction/retranscription/reformat/re-delivery results,
exports a versioned package with at most one CAF, and transactionally deletes
the session and owned audio. Re-delivery captures a fresh empty caret only after
the explicit three-second delay and records failed attempts. Migration lazily
backfills immutable baseline results without rewriting session rows. Unit,
database-reopen, corrupted-evidence, 5,000-session search, model, export,
playback, and signed packaged-UI checks cover the journey; measured warm search
p95 is 2.639 ms against the 250 ms requirement.

### M7 — Bound storage without surprise

When age, byte, or artifact-count quota is exceeded, cleanup skips active, pinned,
and sole recovery artifacts; removes oldest unpinned audio to the low-water mark;
retains transcript metadata; and records an Audio-expired reason. Derived cache
eviction does not change History. `Unlimited`, zero retained audio, low-disk
cleanup, corrupt sizes, and concurrent finalization have explicit results.

Implemented evidence: the Swift baseline and dependency-free Rust planner pass
one versioned cross-language CUJ fixture; a versioned C ABI passes layout and
real-consumer checks. Separate SQLite session and retention actors share one
injected History service; preference schema 6 exposes independent macOS
controls; and database-reopen tests cover startup/post-finalization enforcement,
protected recovery audio, missing or invalid sizes, low disk, rapid shared-
service finalization, search preservation, expiration provenance, and revision-2
export.

### M8 — Recover from interruption and crash

A crash or process kill during capture leaves at most one partial artifact.
Startup reconciles it into a recoverable session or removes it under the partial
retention rule. Corrupt SQLite state, an orphan audio file, full disk, audio-route
loss, and model cancellation do not block app launch or lose unrelated sessions.

**Current evidence:** one pure planner and one startup actor reconcile exact
app-owned partial, orphan, and expiration-quarantine names before retention.
Finalization, audio import, and archive restore complete that one-time
reconciliation before creating a new finalized artifact, so concurrent
maintenance cannot recover an in-flight session.
Readable audio becomes a typed Recovery session with empty immutable evidence,
whole-file playback, and retranscription; unpinned recovered audio expires after
24 hours while its session remains. Recent unreadable audio is preserved and
stale unreferenced audio is removed. Malformed rows are isolated, a physically
corrupt SQLite family is preserved before clean storage opens, and audio
finalization failure stores completed text before surfacing its typed failure.
Deterministic planner, real CAF/SQLite, export, retention, corruption, and
presentation tests cover the journey. The current corpus passes 475 tests in 71
suites, including a retention-first recovery ordering regression.

### M9 — Remain local and degrade honestly

Airplane/no-network state does not change successful local behavior. A remote-
capable provider is rejected before content transfer. When formatting is
unavailable or misses its deadline, validated Raw/Edited text is delivered under
the declared fallback policy. When ASR is unavailable, audio remains recoverable
and the target is not modified.

**Current evidence:** every formatting adapter declares typed provider identity
and locality. The router admits only in-process and fixed numeric-loopback
providers, validates response identity, and invokes no method on a remote-
capable adapter. A production-controller acceptance test rejects such an
adapter, inserts deterministic Edited fallback once, and stores playable audio.
A separate real CAF/SQLite test fails ASR after a captured buffer, performs no
formatting or target mutation, and stores empty text stages with delivery not
attempted and playable audio. Existing deadline, provider-unavailable,
validation, late-output, and target-revalidation tests cover the other fallback
branches. The complete 475-test/71-suite host corpus passes.

### M10 — Share one session behavior across triggers

A physical Control, Hold chord, latch chord, and in-app record button invoke the
same Voice-session state and History contract. Trigger-specific momentary/toggle
semantics remain adapters; none changes ASR, formatting, retention, or delivery
meaning.

**Current evidence:** the physical Action path, exact Hold/latch chord adapter,
and menu-bar record action all submit `DictationCommand` to the process-owned
Local AI dispatcher. Phase-policy tests cover Record, Stop, unavailable, and
post-capture states. Boundary tests cover Hold, double-press latch/finish, and
runtime start/suspend/resume/stop gates. The complete 480-test/72-suite host
corpus passes.

### M11 — Prove the first portable policy boundary

The Swift and dependency-free Rust retention planners produce the same ordered
decisions from one versioned CUJ fixture. A synchronous versioned C ABI exposes
that policy with caller-owned buffers, stable typed errors, and no retained
pointer or callback.

**Current evidence:** Swift and Rust conformance tests share
`Tests/cuj/voice_retention_v1.json`; Rust layout and domain tests pass; and a
real C17 consumer compiles, links, and executes against the optimized static
library. Decision
[`0035`](decisions/0035_portable_voice_c_abi.md) owns the boundary.

### M12 — Import a local recording

**Given** History is available and the user selects a supported local audio
file within configured source-byte, decoded-byte, and duration limits.

**When** the user chooses **Import Audio Recording**.

**Then** the app balances access to the selected file, runs local ASR and the
selected Style, streams the recording into one app-owned CAF, and stores a
searchable session with typed imported-audio provenance. It never changes or
deletes the selected file and never inserts text automatically. Formatting
failure stores the Raw transcript fallback; ASR failure stores replayable audio
with empty text for explicit retranscription. Cancellation, unsupported audio,
corruption, or a breached limit creates no History row or owned artifact.

**Current evidence:** the macOS defaults cap source and decoded audio at 2 GiB
and duration at 12 hours before model work. Actor-owned tests cover the real
streaming CAF/SQLite path, source preservation, Raw/Formatted provenance,
search selection, source/duration/decoded-size rejection, cancellation,
formatting fallback, ASR fallback, and legacy JSON/database defaults. Portable
archive export and restore are owned by M14.
Decision [`0036`](decisions/0036_imported_voice_audio.md) owns the boundary.

### M13 — Admit only verifiable Model packages

**Given** a Model package in a private staging directory and configurable
manifest-byte, installed-byte, and file-count limits.

**When** a platform adapter asks the portable engine to validate it.

**Then** V1 accepts only typed, stage-compatible metadata; mandatory license
evidence; portable canonical paths; a complete link-free declared inventory;
exact file sizes and SHA-256 digests; and, for an approved download, the
out-of-band expected manifest digest. It returns the exact verified identity,
capabilities, resource metadata, byte count, and manifest digest without
retaining caller memory or files. A manual package without an expected digest
is internally verified but not publisher-authenticated.

**Current evidence:** one shared package fixture passes the Rust verifier and a
linked optimized C17 consumer. Rust and ABI tests cover buffer negotiation,
layout, malformed UTF-8, optional manifest pinning, payload tampering,
undeclared files, traversal/nonportable paths, duplicates, stage mismatch,
case-insensitive language aliases, independent limits, empty payloads, and
symbolic links. Decision
[`0037`](decisions/0037_portable_model_package_validation.md) owns the boundary.

### M14 — Move one Voice session without losing evidence

**Given** a user-selected V1 `.voice_history` archive, configurable byte/result
limits, and no network connectivity.

**When** the user chooses **Import → Voice History Archive**.

**Then** the app snapshots and verifies the exact bounded manifest, checksums,
optional CAF, session identity, and immutable result graph before copying audio
into app-owned storage and atomically restoring History. Restore never delivers
text. Reimporting identical evidence is a no-op; a UUID collision with different
evidence, tampering, undeclared entry, link, unsupported schema, or breached
limit creates no row or owned artifact. The final revision 4 macOS archive
migrates during import; all new exports use portable V1.

**Current evidence:** Swift exports and imports the shared V1 fixture and a real
CAF/SQLite round trip. The production importer invokes the statically linked
Rust verifier on its private snapshot, compares fixed identity metadata, then
restores through Swift. Focused suites cover legacy migration, idempotence,
conflict, tampering, inventory, limits, custody, typed Swift/C translation, and
an optimized C17 consumer. Decision
[`0038`](decisions/0038_portable_voice_history_archives.md) owns the boundary.

## iOS journeys

### I1 — Onboard locally

The containing app explains local processing and History retention, requests
microphone permission, validates an installed/imported Model package, guides the
user through adding the custom keyboard, and explains Full Access only when
needed for same-team local handoff. Denial leaves a usable app/keyboard
with exact recovery instructions. No permission prompt originates in the
keyboard extension.

**Current evidence:** the production `apps/ios/voice_input/` target explains
local-only processing before permission, never prompts at cold launch, models
undetermined/denied/authorized microphone recovery as pure policy, and guides
the exact keyboard setup path. The keyboard writes a bounded this-device-only
presence marker only after Full Access exists; the app uses it to confirm local
handoff. The app also imports a folder under security-scoped access, bounds and
copies it into private storage, invokes the linked Rust validator, preserves
language and provenance metadata, cleans failed staging, and lists a valid
manual package without claiming runtime readiness. Focused tests execute the
real iOS Rust symbol and cover limits, links, tampering, identity conflicts,
idempotence, corrupt records, configured library byte/version caps, explicit
removal, and user-visible import availability. The default library cap is 12
GiB or eight installed versions; neither limit silently evicts a package.

### I2 — Dictate from a warm custom keyboard

**Given** the custom keyboard is visible in an editable nonsecure field and the
containing app already owns a confirmed capture.

**When** the user speaks and taps the keyboard mic to stop.

**Then** the keyboard reflects only confirmed Capture-owner state; the containing
app records and runs local ASR/formatting; the keyboard requests one matching
stop and reflects bounded status; final text is inserted once through
`textDocumentProxy`; and the containing app stores History. No audio is captured
by the extension.

**Current C4 evidence:** the containing app can persist one compatible active
ASR package, prewarm a pinned whisper.cpp context, revalidate all selected bytes
through Rust immediately before use, and convert its CAF to timed Raw text. One
shared deterministic engine applies typed spoken edits and validated semantic
paragraph/list blocks while preserving Raw. The containing app commits Raw,
Edited, Formatted, timed segments, Style, model provenance, digest-verified CAF,
and retention metadata to searchable local History before publishing
keyboard-ready text. History reload, escaped search, playback, age/byte/count
expiry, transcript preservation, and partial/orphan cleanup pass real
SQLite/filesystem tests. Wrong runtimes, missing selection, changed bytes,
bounded-output failures, and unavailable History remain explicit and do not
invent or deliver text. A native C integration test crosses the production
framework with pinned model/audio and enforces a permissive RTF gate. App and
keyboard expose separate persisted surface defaults for all five Styles. The
schema-V2 stop command freezes one explicit Style for the matching session,
real-Keychain tests cross recording/stop/ready, and insertion receipts reject a
re-published result by session identity. The keyboard persists its claim before
host-field insertion, so a crash can omit delivery but cannot replay it; History
remains available for recovery. Physical signed-device keyboard evidence
remains required before I2 is accepted.

**Gate K0 evidence:** a signed app, keyboard, and Control Center extension share
only bounded this-device-only Keychain records. The containing app records a real
16-kHz mono CAF; the enabled keyboard types in Messages, requests a result, and
inserts the matching result once. Policy, persistence, latency, capture, and UI
tests cover the deterministic handoff behavior.

### I3 — Start when the containing app is cold or suspended

Apple does not permit a keyboard extension to launch its containing app, and a
custom keyboard has no microphone access even with Full Access. The keyboard mic
therefore never claims to start a cold capture. It presents one accurate action:
start Voice from the containing app, its Control Center control, or another
approved `AudioRecordingIntent`, then return to the field. The containing app
confirms capture and publishes a Live Activity before background continuation.

Gate K0 confirms the documented ownership and handoff design in the simulator
and a correctly entitled generic-device build. The paired physical iPhone is
reachable, but installation remains required production evidence because its
free provisioning profile already contains three unrelated development apps.
No existing app is removed automatically. This does not block independent C4
implementation. Decision
[`0040`](decisions/0040_ios_keyboard_activation_and_handoff.md) owns the boundary.

### I4 — Type without Full Access

Without Full Access, QWERTY typing, deletion, shift, return, space, and the globe
key remain functional. Mic is visibly unavailable with concise setup guidance.
No text, audio, or model operation crosses the unavailable shared-Keychain
boundary.

### I5 — Respect unsupported fields

Secure fields receive the system keyboard. Phone-pad, numeric, one-time-code,
banking, managed-device, and custom host fields follow declared capabilities.
The keyboard never starts capture where insertion or privacy cannot be assured;
it reports unsupported state without retaining target context.

**Current evidence:** iOS itself replaces the extension for secure and phone-pad
fields and permits hosts to reject custom keyboards. If the extension is
present, a typed UIKit boundary allows only recognized general-text traits;
numeric, credential, one-time-code, payment, sensitive-identifier, and unknown
custom traits keep typing available while disabling Voice. Unsupported controls
do not read shared capture state. Decision
[`0045`](decisions/0045_ios_host_field_and_delivery_target_safety.md) owns the
boundary. Physical-iPhone host-field evidence remains required.

### I6 — Choose a Style without target identity

The keyboard exposes a compact Style selector and remembers the explicit
keyboard/surface default. It does not infer the host application's identity.
Casual, Formal, Technical, Natural, and Verbatim outputs pass the same shared
formatting fixtures as macOS.

**Current evidence:** both surfaces persist only a validated stable identifier.
The keyboard displays a compact menu without widening its extension boundary,
and the containing app exhaustively maps every identifier to the canonical
shared `VoiceStyle`. The exact stop command, History record, and rendered result
retain the selected Style; later preference changes cannot alter the in-flight
session. Decision
[`0044`](decisions/0044_ios_style_qualified_keyboard_delivery.md) owns the
boundary.

### I7 — Survive interruption and background transitions

Incoming calls, Siri, audio-route changes, lock, background expiration, low power,
thermal pressure, and another app taking the microphone produce explicit state.
Live Activity/system recording indication matches Capture ownership. A partial
session remains recoverable; automatic resume never occurs after privacy-
sensitive interruptions without an approved rule.

**Current evidence:** the containing-app actor owns recorder, audio session,
Live Activity, heartbeat, and bounded background-finalization task. Exhaustive
notification mapping distinguishes route swaps from category/override changes;
policy stops calls/Siri-class interruptions, media-service loss, missing
background ownership, critical thermal pressure, and background expiration.
Low Power Mode and serious thermal pressure continue with explicit advisories.
Interruption commits typed Recovery History before ownership release when
storage is available; first History access adopts exact readable partial/orphan
audio, preserves damaged or unknown files, migrates revision 1, and expires the
sole recovery artifact after 24 hours. No path automatically resumes. Signed
physical-iPhone lifecycle evidence remains open under the free-profile limit.
Decision
[`0046`](decisions/0046_ios_capture_lifecycle_and_recovery.md) owns the boundary.

### I8 — Detect a stale service

If the containing app is killed, upgraded, or no longer publishing a valid
heartbeat, the keyboard stops showing active state, never queues unbounded audio
commands, and offers one restart action. Duplicate or late shared-Keychain messages
cannot insert text twice or revive a completed session.

**Current evidence:** Recording and Transcribing publish 500-millisecond
heartbeats, and the keyboard expires active state after three seconds. It polls
only after one exact stop, then clears its ephemeral target, stops polling, and
shows one `Restart…` action with the approved app/Control Center instructions.
Missing, future, expired, and unknown-schema heartbeats fail closed. Ready must
carry a strictly newer sequence than the stop-triggering snapshot, while a
durable same-session insertion receipt dominates every replayed phase. The
app alone consumes the single command slot and rejects commands older than 30
seconds. Pure
policy, blocked-finalization actor, and real-Keychain tests cover the journey;
physical kill/suspension/upgrade evidence remains open. Decision
[`0047`](decisions/0047_ios_stale_service_recovery.md) owns the boundary.

### I9 — Recover failed insertion

If the host field disappears, rejects insertion, or changes during finalization,
the transcript remains in containing-app History. The keyboard offers bounded
retry/copy behavior only for the same confirmed session and target state. A late
completion from an earlier session never overwrites a newer field.

**Current evidence:** writing a keyboard stop captures only the session UUID,
UIKit's opaque document UUID, and an in-memory revision advanced by every text
or selection callback. All must still match before the durable insertion claim
and first automatic attempt. If no text-change callback arrives within 500
milliseconds, `Recover…` offers one explicit same-process retry and one local-
only copy capped at 256 KiB and expiring after ten minutes. Every action
revalidates Full Access, field eligibility, exact Ready session/sequence/text,
durable receipt, document, and revision. Text change confirms delivery;
selection, field, session, result, receipt, or extension-process change directs
recovery to containing-app History. History also exposes bounded copy. No path
retains target text or host identity, and no automatic path retries. Pure policy
tests cover exact matches, every mismatch class, retry exhaustion, copy bounds,
and expiry. Physical host rejection/callback evidence remains open. Decision
[`0048`](decisions/0048_ios_bounded_insertion_recovery.md) owns the boundary.

### I10 — Remain offline and within storage limits

Airplane mode completes keyboard and in-app capture with local models. iOS
applies its age/byte quota, pinning, partial recovery, Data Protection, and low-
disk rules without blocking capture. Installed active models are not silently
evicted as History cache. The Model library separately rejects admission at its
configured byte or installed-version cap and permits explicit package removal.

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
2. the observable contract and deterministic Raw/Edited fallback;
3. macOS 90-day/2-GiB/5,000-artifact and iOS
   90-day/1-GiB/2,000-artifact audio defaults;
4. 24-hour retention for failed but recoverable partial artifacts;
5. Gate K0 and an honest cold-start/app-switch experience; and
6. benchmark-selected deployment floors and Model packages.

These choices do not approve release promotion or `dev` → `main`. Model,
signed-device, and App Review findings are implementation evidence, not new
preference questions.
