# 0047: Bound iOS stale-service recovery

- **Status:** Accepted
- **Date:** 2026-08-27
- **Implements:** [0040](0040_ios_keyboard_activation_and_handoff.md)

## Context

The keyboard can stop an app-owned recording, but it cannot own the microphone,
launch the containing app, or infer that a nonterminal snapshot remains live.
The containing app may be killed, suspended, or replaced while recording or
transcribing. A stale single-slot command, replayed snapshot, or extension
restart must not create an unbounded wait or a second insertion.

## Decision matrix

| Criterion | Recording-only heartbeat | Active-phase heartbeat | Fixed finalization timeout |
| --- | ---: | ---: | ---: |
| Detects app loss while recording | 5 | 5 | 1 |
| Detects app loss while transcribing | 0 | 5 | 3 |
| Permits variable local model latency | 5 | 5 | 1 |
| Keeps keyboard state truthful | 2 | 5 | 2 |
| Uses documented public APIs | 5 | 5 | 5 |
| **Total** | **17** | **25** | **12** |

## Decision

The containing app publishes a heartbeat throughout both Recording and
Transcribing. The default pulse is 500 milliseconds; the keyboard treats an
active snapshot as stale after three seconds, if its heartbeat is missing or
future-dated, or if its schema is unknown. Ready, Interrupted, Failed, and Idle
are terminal snapshots and do not publish heartbeats.

The keyboard polls the bounded Keychain snapshot only after it has written one
exact stop command and captured an ephemeral delivery target. A stale service
clears that target, stops polling, and exposes one `Restart…` action. That action
shows the approved containing-app or Control Center restart path. It does not
claim to launch or wake the app. Command acceptance remains 30 seconds, and the
record remains an atomic single slot; the keyboard does not race the app by
deleting it.

Delivery requires the same session, document, and host-change revision plus a
result sequence strictly newer than the snapshot that caused the stop command.
A durable insertion receipt for the same session wins over every later or
replayed active/result snapshot. A stale, duplicate, regressed, or late message
therefore cannot revive a completed journey or insert twice.

## Verification

Pure policy tests cover missing, expired, future, and unknown-schema heartbeats;
same-session replay after insertion; and strictly newer delivery sequences. An
actor test holds local ASR open and proves Transcribing heartbeats continue.
Real Keychain tests retain the one-command bound and durable insertion claim.
Physical keyboard kill, suspension, and upgrade evidence remains required.

## Sources

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple custom keyboard guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
- [Apple AudioRecordingIntent](https://developer.apple.com/documentation/appintents/audiorecordingintent)
