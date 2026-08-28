# Voice Input for iOS

## Run

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/check_ios.sh
scripts/build_ios_device.sh
```

Override the simulator when needed:

```bash
HC_IOS_SIMULATOR_UDID='<simulator-udid>' \
  scripts/check_ios.sh
```

The check grants microphone access only to the Voice Input bundle on the selected
simulator so the real-capture UI test is deterministic. It does not change
physical-device privacy settings. It also rejects network clients, network/cloud
capabilities, and Network.framework linkage in iOS product sources.

`build_ios_device.sh` reads the private `HC_EXPECTED_TEAM_ID` from
`.env.local`. It emits the signed `.app` path but does not install it.

## Current scope

This production target promotes the Gate K0 ownership boundary into the
repository's canonical `apps/ios/voice_input/` location. Local-first onboarding
explains privacy before permission, requests microphone access only after an
explicit tap, provides exact denial recovery, and observes the enabled keyboard
through the same-team local handoff.

The containing app owns microphone capture and the audio file. The keyboard
remains a normal QWERTY keyboard and exchanges only bounded snapshot and command
JSON through a same-team local Keychain access group. The records use a this-
device-only protection class and never opt into iCloud synchronization.

The containing app can import a local Model-package folder. It copies only a
bounded, link-free inventory into private storage, validates the exact package
through the linked Rust boundary, installs matching identity/version bytes
atomically, and preserves the original folder. Installed models use Data
Protection and stay outside OS backup. Files-picker imports are labeled manual;
the user explicitly selects an admitted compatible package for transcription.
The library defaults to 12 GiB and eight installed versions. These limits are
configurable policy; rejected admission leaves every installed package
unchanged. The app never implicitly evicts a model and provides explicit
removal of only its private installed copy.

An active compatible package now drives pinned local whisper.cpp file ASR in
the containing app. The runtime revalidates selected model bytes before load,
prewarms one actor-owned context, and returns bounded Raw text with timed
segments. Neither extension links the runtime or can read model bytes.

The app applies the shared deterministic spoken-edit, casing, list-intent,
typed list-normalization, and semantic-formatting core, then commits Raw,
Edited, Formatted, Style, model provenance, and copied audio evidence to
searchable local SQLite History before publishing text.
History supports retained-audio playback and configurable age, byte, and count
caps; its default 90-day, 1-GiB, 2,000-artifact policy expires audio without
deleting transcripts. History storage presets persist in a versioned local
preference. Users can pin retained successful or Recovery audio. Automatic
maintenance skips pinned audio, restores a 1 GiB basic-volume free-space
reserve, and surfaces failures without invalidating a durable capture. Future or
damaged preference state is preserved read-only instead of being overwritten.

The keyboard cannot access the microphone or launch the containing app. A cold
capture starts from the containing app, its stateful Control Center/Lock Screen
control, the Action button, Siri, or Shortcuts. The containing app owns capture
and publishes a Live Activity with an exact stop action. System-surface stops
use Natural; in-app and keyboard stops retain their selected Style. While the
app owns capture, the keyboard can request stop, wait for a matching result, and
make one automatic insertion attempt. If UIKit cannot confirm that update, one
explicit same-process retry and one 10-minute local-only copy remain available
only while the exact result and target still match; otherwise History is the
recovery path. App and keyboard menus persist separate defaults for Natural,
Casual, Formal, Technical, and Verbatim. The keyboard freezes its selection on
the exact stop command, and a matching session can insert only once. The durable
insertion claim precedes the host-field change; after a crash, History is the
recovery source for a claimed result that did not reach the field. Physical
iPhone keyboard evidence remains required.

After a keyboard-free capture, use History to copy or share the completed text,
or retrieve the bounded Ready result from the keyboard later. The app never
guesses a target field. On relaunch, orphaned Live Activities end and old active
state becomes Interrupted while exact partial audio remains recoverable.

Recording and Transcribing publish local heartbeats. If the app stops responding
for three seconds, the keyboard clears its pending target, stops polling, and
shows one `Restart…` action with the app/Control Center restart steps. It never
launches the app. Delivery also requires a result sequence newer than the stop
request; the durable session receipt defeats every replay after insertion.

Voice is available only in recognized general-text fields. Constrained,
sensitive, and unverified traits keep the keyboard usable but disable its mic.
The keyboard retains only an ephemeral session/document/change identity while
waiting; changing text, selection, or fields sends recovery to History instead
of inserting at a changed target.

The containing app maps audio interruptions, route changes, media-service loss,
background transitions, Low Power Mode, and thermal pressure into explicit
capture decisions. Background recording continues only while its Live Activity
is owned. Capture never automatically resumes after a sensitive interruption.
Stopped audio gets a bounded background-finalization task; expiration or another
stop condition preserves the exact partial as playable Recovery History when
storage is available. On first History access after launch, only readable exact
session artifacts are adopted. Damaged, empty, unknown, and noncanonical files
remain untouched and cannot hide valid History. Recovery audio expires after 24
hours without inventing transcript or model evidence.
