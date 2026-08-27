# 0040: Keep iOS capture in the containing app

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:** [0029](0029_local_voice_platform_expansion.md)

## Context

The iOS product requires a full custom keyboard with a voice control, but Apple
does not grant keyboard extensions microphone access. App Review guideline 4.4.1
also prohibits a keyboard from launching apps other than Settings. Gate K0 must
define an honest activation and handoff before production iOS work.

## Decision matrix

| Criterion | App-owned capture plus shared Keychain | App-owned capture plus App Group | Keyboard-owned capture | Keyboard launches app |
| --- | ---: | ---: | ---: | ---: |
| Documented public API | 5 | 5 | 0 | 0 |
| No-cost signed probe | 5 | 1 | 0 | 0 |
| Local privacy | 5 | 5 | 4 | 4 |
| Bounded command latency | 5 | 5 | 5 | 2 |
| Large-payload suitability | 2 | 5 | 2 | 2 |
| Cross-platform engine compatibility | 5 | 5 | 3 | 2 |
| **Total** | **27** | **26** | **14** | **10** |

## Decision

The containing app exclusively owns `AVAudioSession`, microphone permission,
audio capture, local inference, History, model packages, and Live Activity
publication. The keyboard owns ordinary text input, voice status and stop
control, and final insertion through `textDocumentProxy`. It never requests the
microphone, records audio, infers recording state, or launches the app.

App, keyboard, and Control Center extension share one access-group Keychain
service. Records contain only versioned, size-bounded session snapshots and one
command slot. They use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
`kSecAttrSynchronizable=false`. Audio, model bytes, History, logs, host identity,
and target context never enter Keychain. Final text is capped before transport;
larger results remain available in containing-app History for explicit copy.

Cold capture starts through the containing app or a documented system surface
that invokes `AudioRecordingIntent`, such as Control Center. Intent-started
recording publishes a Live Activity before background continuation. The user
returns to the target application manually. If no confirmed app-owned session
exists, the keyboard voice control gives this instruction and never displays a
false recording state.

The no-cost provisioning profile rejected App Group entitlements, while the
same-team Keychain group signed and ran across the app and keyboard. A later App
Group is not required by the product contract. Moving large non-audio handoff
payloads to one would require measured need, matching provisioning, migration,
and a superseding decision.

## Consequences

- The keyboard can stop and retrieve a warm, confirmed session but cannot start
  a cold session by itself.
- Full Access enables only same-device Keychain coordination; QWERTY, delete,
  shift, return, space, and globe remain usable without it.
- The keyboard polls only while awaiting a matching result. Sequence and session
  identity prevent duplicate or late insertion; commands older than 30
  seconds or dated in the future are consumed without execution.
- The shared transport remains replaceable behind a narrow store protocol; the
  portable engine, schemas, and model packages remain independent of UIKit and
  Keychain.

## Evidence

- `apps/ios_probe/`
- `scripts/check_ios_probe.sh`
- `scripts/build_ios_probe_device.sh`
- [Apple custom keyboard open-access capabilities](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard)
- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple Audio Recording Intent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
- [Apple Keychain Sharing](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
