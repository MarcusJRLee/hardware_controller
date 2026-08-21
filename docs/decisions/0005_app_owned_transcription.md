# 0005: App-owned local transcription

- **Status:** Accepted and implemented in 1.1.0
- **Date:** 2026-07-26
- **Supersedes:**
  [`0002_dictation_strategy.md`](0002_dictation_strategy.md)

## Context

The system Dictation bridge cannot observe or own macOS Dictation state. It
also depends on the user configuring the same custom shortcut in two places.
Physical testing found that correct local input state and successful event
dispatch do not prove that system Dictation started or stopped. That boundary
prevents the app from giving authoritative listening, finalizing, and failure
status.

The user chose an app-owned transcriber as the final Dictation architecture.
The product must retain macOS 15 support, keep audio processing local, type into
the focused app, preserve Hold and Toggle semantics, and keep audio work off the
HID hot path.

Apple's modern `SpeechAnalyzer` and `DictationTranscriber` APIs are available
on macOS 26 or later. The older `SFSpeechRecognizer` streaming API is available
on the existing deployment range and can be configured to require on-device
recognition.

## Recognition decision matrix

| Criterion | macOS 26-only modern API | Dual Apple backends | Keep shortcut bridge |
| --- | --- | --- | --- |
| Keeps macOS 15 support | No. | Yes. | Yes. |
| App owns listening state | Yes. | Yes. | No. |
| Strict local-processing policy | Yes, with installed assets. | Yes, by rejecting a legacy locale without on-device support. | Not enforceable by this app. |
| Implementation surface | Smallest owned implementation. | Two adapters behind one contract. | Smallest overall. |
| Long-term API direction | Best. | Best on current systems. | No. |

## Text-delivery decision matrix

| Criterion | Quartz Unicode events | Accessibility selected-text insertion | Automatic pasteboard fallback |
| --- | --- | --- | --- |
| Preserves the target's editing behavior | Usually, but live validation found accepted events were not delivered to a SwiftUI field. | Yes for editors that expose settable `AXSelectedText`; it replaces only the current selection. | Usually. |
| Avoids replacing the whole field | Yes. | Yes. | Yes. |
| Avoids changing the user's clipboard | Yes. | Yes. | No. |
| Works with the existing Accessibility grant | Yes. | Yes. | Yes. |
| Detects focus safety before delivery | Yes, through a separate Accessibility preflight. | Yes. | Yes. |

## Decision

Replace the macOS Dictation shortcut bridge with an app-owned transcription
session:

- On macOS 26 and later, use `SpeechAnalyzer` with
  `DictationTranscriber`, system-managed language assets, and an
  `AVAudioEngine` input stream.
- On macOS 15 through 25, use `SFSpeechRecognizer` with
  `SFSpeechAudioBufferRecognitionRequest`. Set
  `requiresOnDeviceRecognition` and refuse to start when the selected
  recognizer does not support on-device recognition. Never fall back to a
  server-backed request.
- Keep the deployment target at macOS 15. Both adapters implement one
  transcript-stream contract and expose explicit unsupported-locale,
  missing-asset, permission, audio, cancellation, and recognition failures.
- Request Microphone permission on every supported runtime. Request Speech
  Recognition permission only for the legacy `SFSpeechRecognizer` backend.
  Include both specific `Info.plist` usage descriptions. Accessibility remains
  required for safe focused-app targeting and text delivery.
- Capture the focused application and editable Accessibility element when a
  session begins. Reject secure text fields. Before every insertion, verify
  that the same application and editable element still have focus.
- Deliver only finalized transcript segments through the target's settable
  `AXSelectedText` attribute. This inserts at the current selection without
  reading or replacing the field's full value. Show volatile text in Hardware
  Controller, but never replace already-inserted text with a partial
  hypothesis.
- If focus changes or a target rejects selected-text insertion, stop automatic delivery,
  retain the final transcript in memory, and offer an explicit **Copy
  transcript** recovery action. Never modify the pasteboard automatically.
- Keep at most one transcription session. Hold begins on press and finalizes on
  release. Toggle begins on one press and finalizes on the next. Device
  disconnect, profile replacement, permission loss, sleep, and shutdown cancel
  or finalize through the same serialized owner.
- Capture audio only in memory. Do not persist or log audio, transcript text,
  focused-field contents, or target-app content. Keep the app without network
  entitlements.

The existing `.dictation` Action identity and Hold/Toggle domain semantics
remain stable. A Profile migration removes the now-obsolete shortcut
configuration only after the owned transcriber passes its release gates.

## Consequences

- Hardware Controller can report authoritative preparing, listening,
  finalizing, inserting, completed, and failed states.
- Dictation no longer depends on a matching macOS Keyboard setting.
- The app gains Microphone onboarding everywhere and Speech Recognition
  onboarding on macOS 15–25.
- macOS 15–25 and macOS 26+ need separate system-boundary tests.
- Some custom editors do not expose settable selected text. These failures are
  visible and recoverable, not hidden behind a clipboard mutation.
- The HID callback-to-dispatch metric continues to end when the serialized
  transcription command is accepted. Audio startup and first/final transcript
  latency are separate metrics.

## Version 1.1.1 implementation correction

A real in-app test exposed two system-boundary details:

- AppKit traps when the app changes its own text view through Accessibility
  from a cooperative worker. Same-process selected-text insertion therefore
  runs on the main thread; external-app insertion remains off the main actor.
- Speech asset resolution and the first microphone-format query were
  press-time costs. The app now resolves both during authorized idle startup
  and keeps the speech model reserved for the process lifetime. It does not
  start the audio engine or capture audio until the control is pressed.

## Sources

- [Apple: `SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: `DictationTranscriber`](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [Apple: requiring on-device recognition](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition)
- [Apple: checking on-device recognition support](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [Apple: setting Accessibility attribute values](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
