# Voice Input for iOS

```bash
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/check_ios.sh          # Simulator build, unit and UI tests, local-only scan.
scripts/build_ios_device.sh   # Signed device .app (reads .env.local); does not install.
scripts/install_ios.sh        # Build, install, and launch on a connected iPhone.
```

Pick a simulator with `HC_IOS_SIMULATOR_UDID=<udid> scripts/check_ios.sh`. The
check grants microphone access only to Voice Input on that simulator.

| Path | Owns |
| --- | --- |
| `app/` | Capture, transcribe.cpp ASR, formatting, History, Model library, onboarding. |
| `keyboard/` | QWERTY keyboard, voice status, one insertion attempt, recovery. |
| `system_capture/`, `widgets/` | Control Center control, App Intents, Live Activity. |
| `shared/` | Bounded Keychain handoff shared by app and extensions. |
| `tests/`, `ui_tests/` | Unit tests and simulator UI tests. |
| `project.yml` | XcodeGen source; regenerate with `scripts/generate_ios_project.sh`. |

Behavior and proofs: [user guide](../../../docs/user_guide.md#ios-voice-input),
[architecture](../../../docs/architecture.md), and journeys I1–I11 in
[voice_cujs.md](../../../docs/voice_cujs.md#ios).
