# 0034 — Converge macOS Voice triggers before session orchestration

## Status

Accepted and implemented for macOS M10.

## Context

Physical Controls and the independent Voice chord already reached the same
Local AI Dictation dispatcher. The app lacked a direct record action, and each
new trigger could otherwise grow its own capture, formatting, retention, or
delivery behavior. A button in the main window would also activate Hardware
Controller and replace the external text target immediately before capture.

## Decision

- Keep `DictationCommand` (`begin`, `finish`, and `cancel`) as the only command
  boundary between every trigger adapter and the process-owned Local AI
  Dictation controller.
- Route physical Controls through the Action executor, Hold/latch chords through
  `VoiceKeyboardTriggerController`, and the app record action through
  `ApplicationRuntime`; all three submit to the same serialized Local AI
  dispatcher.
- Put **Record Voice** in the menu-bar control surface. Do not add a main-window
  record button that would steal the intended target application's focus.
- Derive the button from the authoritative Local AI phase. Idle, completed, and
  failed sessions may begin when Local AI is available; preparing or listening
  sessions may finish even if readiness changes; post-capture work is disabled.
- Reject app-initiated commands when the runtime is stopped or suspended, and
  reject begin while Local AI Dictation is unavailable. Session ownership
  remains idempotent below presentation.
- Keep trigger-specific Hold, Toggle, and double-press interpretation in input
  adapters. No trigger may specialize ASR, spoken edits, formatting, History,
  retention, target validation, or delivery.

## Consequences

- A new platform or trigger needs only a typed command adapter and lifecycle
  gate; it cannot silently create a second Voice workflow.
- Menu-bar capture keeps the external application available as the target while
  presenting clear Record, Stop, and finishing states.
- Presentation can miss an intermediate snapshot without duplicating a session;
  the serialized dispatcher and controller remain authoritative.

## Evidence

Boundary tests cover Control-to-dedicated-dispatcher routing, Hold behavior,
double-press latch and finish, runtime start/suspend/resume/stop gates, and every
record-button phase. The complete host corpus passes 480 tests in 72 suites.
