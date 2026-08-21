# 0002: First-release Dictation strategy

- **Status:** Superseded by
  [`0005_app_owned_transcription.md`](0005_app_owned_transcription.md)
- **Date:** 2026-07-24

## Context

The first workflow needs to dictate into the currently focused text field with
Momentary and Toggle pedal behavior. The app must remain local-first. macOS
offers user-facing system Dictation and speech-recognition frameworks, but it
does not expose a supported public API for an external app to own system
Dictation's exact active state.

## Decision matrix

| Criterion                                | Bridge macOS Dictation shortcut                              | Apple on-device Speech API                                | Bundled local speech model                                           |
| ---------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------- | -------------------------------------------------------------------- |
| Text reaches arbitrary focused apps      | Native system behavior.                                      | App must insert text through Accessibility.               | App must insert text through Accessibility.                          |
| Momentary control                        | Emulated around a system toggle; state can diverge.          | App owns capture start/stop.                              | App owns capture start/stop.                                         |
| Strictly on-device guarantee             | Depends on macOS settings, language, and model availability. | Can require on-device recognition when supported.         | Yes after local model installation.                                  |
| First usable version                     | Smallest scope.                                              | Medium scope: audio, recognition, editing, and injection. | Largest scope: model lifecycle, performance, packaging, and editing. |
| Native dictation editing and punctuation | Yes.                                                         | Must be designed and tested.                              | Must be designed and tested.                                         |
| App microphone permission                | No.                                                          | Yes.                                                      | Yes.                                                                 |
| App network entitlement                  | No.                                                          | No when on-device is required.                            | No.                                                                  |
| Runtime/package weight                   | Minimal.                                                     | System-managed.                                           | Potentially large.                                                   |

## Decision

For the first release, bridge the user-configured macOS Dictation shortcut with
synthetic keyboard events. Give the app no network entitlement. The app does not
capture or store audio.

- In **Momentary** mode, Control down requests Dictation start and Control up
  requests Dictation stop.
- In **Toggle** mode, successive Control-down transitions alternate between
  start and stop; releases do nothing.
- Repeated held reports never retrigger either mode.
- Device removal and normal app termination invoke idempotent stop cleanup when
  the app believes Dictation is active.
- Onboarding links to Keyboard settings, records the chosen shortcut, and
  verifies it in a focused test field.

Because the bridge cannot query authoritative system Dictation state, the
Phase 2 spike must test manual shortcut use, rapid press/release, silence
timeout, focus changes, permission failure, and system-initiated stops. If those
cases cause unsafe or frequent divergence, reject this proposal and move to an
app-owned on-device transcriber.

The UI must say that the app itself has no cloud service. It must not claim that
speech processing remains on-device unless macOS reports that the selected
Dictation configuration supports that promise.

## Consequences

- The first version reuses Apple's dictation quality and arbitrary-text-field
  integration.
- Accessibility permission is required for shortcut injection; microphone
  permission is not required by the app.
- System Dictation settings remain a user-visible dependency.
- Strict “no audio ever leaves the Mac” is not guaranteed by the app alone.
- The Action boundary keeps a later on-device transcriber replaceable without
  changing the hardware Driver, Binding engine, or Profile format.

## Superseding evidence

Physical use showed that the shortcut bridge can successfully dispatch a
configured chord while still failing to provide reliable owned Dictation
state. It also requires two independently configured shortcuts to remain
identical. The user accepted an app-owned transcriber on July 26, 2026.

## Sources

- [Apple: Dictate messages and documents on Mac](https://support.apple.com/guide/mac-help/mh40584/mac)
- [Apple: `CGEvent`](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Apple: on-device speech-recognition requests](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
