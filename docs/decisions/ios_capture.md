# iOS capture and system surfaces

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0040, 0046, 0050

## Context

Apple gives keyboard extensions no microphone, and App Review guideline 4.4.1
forbids a keyboard from launching apps other than Settings. iOS can also
interrupt recording for calls, Siri, route changes, media-service loss,
background expiry, or heat. Capture must stay owned, recoverable, and never
resume on its own.

| Criterion                  | App capture + shared Keychain | App capture + App Group | Keyboard capture | Keyboard launches app |
| -------------------------- | ----------------------------- | ----------------------- | ---------------- | --------------------- |
| Documented public API      | 🟢 Yes.                       | 🟢 Yes.                 | 🔴 No microphone. | 🔴 Review rejection. |
| Free signing profile       | 🟢 Works.                     | 🔴 Entitlement rejected. | 🔴 —            | 🔴 — |
| Large payloads             | 🟠 Bounded records.           | 🟢 Files.               | 🟠 —             | 🟠 — |

| Criterion                  | Stateful control + start/stop intents | Start-only control | Extension recording |
| -------------------------- | ------------------------------------- | ------------------ | ------------------- |
| System surfaces            | 🟢 Control Center, Lock Screen, Action button, Siri, Shortcuts, Live Activity. | 🟡 Start only. | 🔴 Unsupported. |
| Exact stop identity        | 🟢 Fresh session snapshot.            | 🟠 App or keyboard only. | 🔴 Ambiguous. |

## Decision

**Ownership**

- The containing app alone owns `AVAudioSession`, microphone permission,
  capture, inference, History, Model packages, and Live Activities, each behind
  an actor. The keyboard owns typing, voice status and stop, and final
  insertion; it never records, infers recording, or launches the app.
- App, keyboard, and Control Center extension share one access-group Keychain
  service holding only versioned, size-bounded session snapshots and one
  command slot, with `AfterFirstUnlockThisDeviceOnly` and no sync. Audio, model
  bytes, History, logs, host identity, and target context never enter it; final
  text is capped, and longer results stay in History.

**Starting and stopping**

- Cold capture starts in the app or from a system surface invoking
  `AudioRecordingIntent`. The user returns to the target app manually; with no
  confirmed session, the keyboard says so and never shows a false recording
  state.
- A stateful WidgetKit control (`ControlValueProvider` plus one
  `SetValueIntent`) works in Control Center, on the Lock Screen, or on the
  Action button. It reads on only for a current three-second Recording
  heartbeat. Start writes one bounded command and foregrounds the app.
- Separate start and stop App Shortcuts serve Siri and Shortcuts. The Live
  Activity offers an exact stop on the Lock Screen and Dynamic Island. Stops
  apply only to the current fresh Recording session; anything else is a no-op.
  A pending command is never overwritten; reload the control only when the
  Recording state changes.
- Style: a system-surface stop uses Natural, an in-app stop the app Style, a
  keyboard stop the keyboard Style. No system path infers a target.
- Completed output commits to History before Ready. Keyboard-free delivery is an
  explicit History copy or share.

**Lifecycle**

- Background recording requires a visible Live Activity; without one, entering
  background stops capture and keeps the partial audio.
- Stop for interruptions, real input-route swaps, media-service loss, critical
  thermal pressure, and background-finalization expiry. Category and override
  changes, Low Power Mode, and serious thermal pressure continue with an
  advisory. Never resume automatically.
- Record into one lowercase `<session>.partial` in protected, backup-excluded
  storage. Before releasing capture, commit interrupted audio as a Recovery
  session with a typed reason.
- Transcribing after Stop gets one bounded background task; expiry invalidates
  the result and keeps the partial as `backgroundExecutionExpired` recovery.
- On activation, if nothing owns a recorder or finalizer, end orphaned Live
  Activities and mark stale Recording or Transcribing snapshots Interrupted,
  leaving partial audio for History to adopt.
- At first History access, adopt only readable, nonempty, exact lowercase
  partial or unreferenced CAF files; leave every other file untouched. A partial
  sharing a committed session's ID is removed only if its digest matches;
  otherwise it is recovered under a new ID. Recovery audio expires after 24
  hours, keeping the empty session.

## Consequences

- The keyboard can stop and collect a warm session but cannot start a cold one.
- `scripts/check_ios_system_capture_metadata.sh` enforces the start, stop, and
  toggle intents and both App Shortcuts.
- An App Group would need measured need, matching provisioning, and a new
  decision.
- Physical evidence still open: calls, Siri, lock, route swaps, recording
  indicator, background expiry, thermal pressure, Lock Screen and Action button
  use, and locked-device stop.
