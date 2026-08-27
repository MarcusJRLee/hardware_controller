# iOS keyboard feasibility probe

## Run

```bash
scripts/check_ios_probe.sh
scripts/build_ios_probe_device.sh
```

Override the simulator when needed:

```bash
HC_IOS_SIMULATOR_UDID='<simulator-udid>' \
  scripts/check_ios_probe.sh
```

The check grants microphone access only to the probe bundle on the selected
simulator so the real-capture UI test is deterministic. It does not change
physical-device privacy settings.

`build_ios_probe_device.sh` reads the private `HC_EXPECTED_TEAM_ID` from
`.env.local`. It emits the signed `.app` path but does not install it.

## Scope

This Gate K0 target proves the supported iOS ownership boundary before the
production iOS application is built. The containing app owns microphone capture
and the audio file. The keyboard remains a normal QWERTY keyboard and exchanges
only bounded snapshot and command JSON through a same-team local Keychain access
group. The records use a this-device-only protection class and never opt into
iCloud synchronization.

The keyboard cannot access the microphone or launch the containing app. A cold
capture starts from the containing app or its Control Center control. While the
app owns capture, the keyboard can request stop, wait for a matching result, and
insert it once. The current result text is an explicit handoff placeholder; local
ASR and formatting belong to the production iOS milestones.
