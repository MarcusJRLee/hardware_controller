# Decision 0050: Finish iOS capture from approved system surfaces

**Status:** Accepted

## Context

The containing app already owns local recording, inference, History, and Live
Activity publication. I11 must make that workflow complete without an active
custom keyboard while preserving exact capture ownership and never guessing a
text field.

| Criterion | Stateful control plus start/stop intents | Start-only control | Extension-owned recording |
| --- | --- | --- | --- |
| Public system surfaces | Control Center, Lock Screen, Action button, Siri, Shortcuts, Live Activity | Start surfaces only | Unsupported |
| Exact stop identity | Fresh session snapshot | App or keyboard only | Ambiguous |
| Microphone owner | Containing app | Containing app | Extension |
| Killed-process recovery | Interrupt snapshot, end orphan activity, retain partial | Stale activity and snapshot | Undefined |
| Target-field privacy | No target | No target | No target |
| Selected | Yes | No | No |

## Decision

- Expose a stateful WidgetKit control backed by `ControlValueProvider` and one
  `SetValueIntent`. People may place it in Control Center, on the Lock Screen,
  or on the Action button. Its value is true only for a current three-second
  Recording heartbeat; stale, future-schema, Transcribing, and inactive state
  render off.
- Keep microphone, model, formatting, and History work in the containing app.
  Start conforms to `AudioRecordingIntent`, writes one bounded start command,
  and foregrounds the app. The app publishes a Live Activity before background
  continuation, as required by `AudioRecordingIntent`.
- Expose separate start and stop App Shortcuts for Siri and Shortcuts. The Live
  Activity presents an exact stop action on the Lock Screen and in the expanded
  Dynamic Island. A stop queues only for the current fresh Recording session;
  duplicate, stale, finalizing, future-schema, or inactive requests are no-ops.
- Use Natural for a stop originating from a system surface. An in-app stop uses
  the app Style, and a keyboard stop uses the keyboard Style. No system action
  infers application or target identity.
- Reload the system control only when the persisted Recording boolean changes,
  not for each heartbeat. A pending single-slot command is never overwritten.
  Repeated starts during owned recording or finalization are harmless.
- On app activation, if the service owns no recorder or finalizer, end orphaned
  Voice Input Live Activities and convert an old Recording or Transcribing
  snapshot to Interrupted. Leave the exact partial untouched so History startup
  reconciliation can adopt it. Never resume automatically.
- Commit completed output to History before Ready. Keyboard-free delivery is an
  explicit History copy or share; a later keyboard may retrieve the bounded
  Ready result. No system path guesses or stores a target field.

## Verification

Pure tests cover inactive start, exact Natural stop, active idempotence,
Transcribing exclusion, stale state, future schema, and command-slot conflict.
Actor tests cover orphan ownership reconciliation, partial preservation, app
activation order, state-change-only control reload, and existing
lock/background finalization policy. Generated App Intents metadata must contain
the Audio Recording start/stop/toggle actions and both App Shortcuts;
`scripts/check_ios_system_capture_metadata.sh` enforces that contract for the
app and Widget extension. Simulator UI checks cover system-surface guidance;
signed device build verification covers entitlements and extension linkage.

## Implications

I11 is complete in source. Physical Lock Screen, Action button, Siri, system
recording-indicator, and locked-device stop evidence remains final signed-iPhone
work. The paired phone still rejects installation only because its free profile
contains three unrelated development apps; none is removed automatically.

## Sources

- [AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Creating controls across the system](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)
- [Displaying Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
