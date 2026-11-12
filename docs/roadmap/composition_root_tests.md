---
title: Unit-test the app's composition roots through injected seams
priority: P2
rank: q
executor: agent
depends_on: []
specs: [.mjrlee_repo_setup/test_ownership.toml]
---

## Outcome

The macOS and iOS composition roots take their side effects through injected seams, and unit tests prove the wiring on both the demo and live paths, with fakes. The side effects are global hotkey registration, the App Support SQLite history, and the audio and speech services. The files are `Sources/HardwareControllerApp/application_runtime_factory.swift`, `Sources/HardwareControllerApp/live_application_process.swift` (start, stop, suspend, resume, keyboard registration) and `apps/ios/voice_input/app/voice_input_app.swift`. Their interim `[[owner]]` entries in `.mjrlee_repo_setup/test_ownership.toml`, which point at the test that builds them, become direct tests.

## Acceptance

- New unit tests cover factory wiring for demo and live modes, and each `LiveApplicationProcess` lifecycle transition, with no global hotkeys registered and no App Support files opened.
- `uv run --no-project python .mjrlee_repo_setup/hooks/test_ownership.py` passes with the three interim `[[owner]]` entries replaced by colocated or same-stem tests.
- `scripts/check.sh` and `scripts/check_ios.sh` pass.
