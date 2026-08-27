# Voice Input for iOS

## Run

```bash
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
physical-device privacy settings.

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

The keyboard cannot access the microphone or launch the containing app. A cold
capture starts from the containing app or its Control Center control. While the
app owns capture, the keyboard can request stop, wait for a matching result, and
insert it once. The current result text remains an explicit handoff placeholder;
local ASR, formatting, History, retention, and model management follow in the
next iOS vertical slices.
