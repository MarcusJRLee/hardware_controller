---
name: verify
description: Prove a Hardware Controller change works in the running app (macOS demo, installed signed build, or iOS simulator) and report evidence. Use before saying a feature or fix works.
---

# Verify

"It compiles" and "tests pass" are not proof. Drive the production user path
on a fresh build and show the observable result a skeptical reviewer would
accept.

## 1. Pick the journeys

Find every row in `docs/voice_cujs.md` the change touches. Run its Proof
tests first; a journey with no proof is a gap to close, not to skip.

## 2. Doctor

```bash
scripts/check.sh          # Formatting, conventions, docs, Rust, C, Swift, release scripts.
scripts/check_ios.sh      # When apps/ios or shared Voice code changed.
```

Evidence from a stale bundle is not evidence: rebuild before driving.

## 3. Drive

| Target | Command |
| --- | --- |
| macOS demo (no pedal, permissions, or signing) | `scripts/build_app.sh --ad-hoc && "dist/Hardware Controller.app/Contents/MacOS/HardwareController" --demo <flags>` |
| Launch smoke | `scripts/smoke_app.sh "dist/Hardware Controller.app" --demo` |
| Installed signed app | `scripts/install_app.sh` (verifies, installs, launches, smokes, checks speech) |
| Installed speech service | `scripts/check_speech_engine.sh` (load, decode, IPC, crash, recover) |
| iOS simulator | `scripts/check_ios.sh`, then the simulator tools for manual paths |

Demo flags (combine freely):

| Purpose | Flags |
| --- | --- |
| Destination | `--ui-general`, `--ui-history`, `--ui-profiles` |
| State | `--ui-pressed`, `--ui-transcribing`, `--ui-transcription-failure`, `--ui-permission-needed`, `--ui-microphone-needed`, `--ui-speech-needed` |
| Appearance review | `--ui-light`, `--ui-dark`, `--ui-increased-contrast`, `--ui-reduce-motion`, `--ui-large-text` |

## 4. Proof bar

- Use the real entry points: UI, menu bar, registered chords, the pedal. Read
  state afterwards; never call internal handlers as the proof.
- Cover every reachable entry point and the success, cancel, error, empty, and
  persistence paths the change affects.
- Verify side effects, not pixels: History rows, files under
  `~/Library/Application Support/com.longdevity.hardwarecontroller/`, the
  inserted text, a relaunch round trip.
- Fakes count only behind the same boundary production uses (process seam,
  model runtime, clock, filesystem faults).
- UI changes: review light, dark, increased contrast, reduced motion, large
  text, and keyboard-only navigation.

## 5. Report

State what you drove, the evidence, and every path you could not reach with
its blocker (physical pedal, signing identity, permission, physical iPhone)
and the closest real path you covered instead. Add an unreachable path to the
game plan's open evidence if it is not already there.
