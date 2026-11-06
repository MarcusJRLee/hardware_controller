# Inputs, Profiles, and Actions

- **Status:** Accepted
- **Updated:** 2026-11-06 (Ask Gemini panel: ⌘W closes a chat, ⌘⇧W the panel; zoom per site)
- **Replaces:** 0004, 0014, 0016, 0018, 0034

## Context

A configured Control must produce only its configured Action. With
nonexclusive access, macOS turns the Infinity 3's buttons into pointer clicks.
Users also need named work modes, a fallback when the Device is absent, and
several ways to start Voice without each growing its own workflow.

| Criterion                         | Global Bindings | Per-Device-model setups | Per-attachment setups |
| --------------------------------- | --------------- | ----------------------- | --------------------- |
| Different Device types            | 🔴 One list.    | 🟢 Yes.                 | 🟢 Yes. |
| Survives reconnect                | 🟢 Yes.         | 🟢 Yes.                 | 🔴 IDs are ephemeral. |
| Honest with identical units       | 🟠 Shares all.  | 🟢 Shares by model.     | 🟠 Pretends to differ. |
| Future stable hardware identity   | 🟠 No seam.     | 🟢 Optional unit ID.    | 🟢 Yes. |

| Fallback mechanism                | Exact Carbon hot key | Global AppKit monitor | Event tap |
| --------------------------------- | -------------------- | --------------------- | --------- |
| Observes only configured chords   | 🟢 Yes.              | 🔴 All keystrokes.    | 🔴 All keystrokes. |
| Reports reservation conflicts     | 🟢 Yes.              | 🔴 No.                | 🔴 No. |
| New privacy permission            | 🟢 None.             | 🟠 Input Monitoring.  | 🔴 Input Monitoring. |

## Decision

**Device ownership**

- Open the exact VEC collection (vendor `0x05F3`, product `0x00FF`, usage page
  `0x0C`, usage `0x03`) with `kIOHIDOptionsTypeSeizeDevice` before activating
  the HID manager. Never seize keyboards, mice, or broader matches.
- Ready means the exclusive open succeeded. Another owner yields an
  unavailable state with Retry. Closing the source releases the Device.
- Physical pressed state stays visible even when Accessibility blocks the
  Action.

**Profiles**

- Each Profile owns ordered per-Device configurations: a typed `DeviceModelID`,
  an optional Driver-supplied stable unit ID, and independent Bindings. Resolve
  the exact unit first, then the model. Infinity 3 uses the model level.
- Create, rename, duplicate, delete, edit, and Make Active. New Profiles give
  connected models No Action; inactive edits never affect the runtime.
- Activation is one ordered transaction: persist atomically, cancel active
  Actions on the runtime queue, clear pressed ownership and install an
  immutable resolver, acknowledge, then publish.
- Older Profile schemas migrate forward. Automatic per-app switching is
  deferred.

**Keyboard fallback**

- A Binding may carry an optional activation chord that selects its existing
  Action and mode. It is opt-in; `⌃⇧⌘D` is offered as a one-click suggestion
  because it avoids documented macOS and VoiceOver shortcuts.
- Register only active-Profile chords with `RegisterEventHotKey`, consuming
  only their press and release. Never install a global monitor or event tap.
- Timestamp in the callback, then dispatch on the same serial queue as
  hardware. Physical and keyboard inputs share one Binding target: Momentary
  ends after the last owner releases; Toggle advances on each distinct press.
- Reject duplicate chords, chords matching a Keyboard Shortcut Action in the
  Profile, and chords with fewer than two modifiers. Name registration
  failures in the Control editor.

**Voice triggers**

- `DictationCommand` (`begin`, `finish`, `cancel`) is the only boundary between
  triggers and the process-owned Local AI Dictation controller. Controls go
  through the Action executor, Voice chords through
  `VoiceKeyboardTriggerController`, and **Record Voice** through
  `ApplicationRuntime`; all reach one serialized dispatcher.
- **Record Voice** lives in the menu bar, never in the main window, which would
  steal the target's focus. Its state derives from the Local AI phase.
- Triggers interpret only Hold, Toggle, and double-press. None may specialize
  ASR, spoken edits, formatting, History, retention, target validation, or
  delivery.

**Ask Gemini**

- **Ask Gemini** is an Action beside the Dictation Actions, with Hold, Toggle,
  and keyboard fallback. It is the third `DictationWorkflow`; beginning any
  workflow first cancels the other two, so one owns the microphone.
- `AskGeminiController` reuses `OwnedTranscriptionController` with a detached,
  final-only target. It never captures, reads, or writes the focused app, so it
  needs microphone and speech permissions but not Accessibility.
- On release the final text goes through the process event relay to
  `AskGeminiPanelController`: a non-activating floating panel that never takes
  focus until clicked. Each question opens a new chat tab, reusing an unused one.
- The panel opens at the saved lock point when its display is connected,
  otherwise on a display other than the one holding the focused window. The
  lock button sets, shows, and returns to the lock point.
- Shortcuts while the panel is the key window: ⌘T, ⌘W (one chat), ⌘⇧W (every
  chat and the panel, like the close button), ⌃Tab/⌃⇧Tab, ⌘⇧]/⌘⇧[, ⌘1–⌘9,
  ⌘⇧+/⌘⇧-/⌘⇧0 for zoom, plus standard editing chords. The panel claims them
  in `performKeyEquivalent`, before the menu bar's Close Window.
- Zoom is stored per site, like a browser, and applied as each page commits.
  Zoom and the lock point persist in `preferences.json` (schema 10; schema 9's
  single zoom moves to `gemini.google.com`). Profiles moved to schema 6 so
  older builds never overwrite a Profile with this Action.
- Network and privacy limits: [Local-only boundary](local_only_boundary.md).

**Failure presentation**

- `lastActionDispatchSucceeded` reports only synchronous executor acceptance.
  Asynchronous failure reconciles Momentary or Toggle ownership without
  rewriting it.
- The typed transcription failure card is the only presentation of Dictation
  failures; the generic Action card is for immediate executor rejection.

## Consequences

- Other pedal software cannot use the Device while the app owns it; quitting or
  crashing releases it.
- The hot path performs only in-memory lookup; persistence and UI never block a
  hardware callback.
- A configured Control works while its Device is disconnected, and the app
  never sees keystrokes beyond registered chords.
- A new trigger needs only a command adapter and a lifecycle gate.
- Open evidence: physical left/center/right actuation, simultaneous presses,
  and confirmation that no pointer click escapes.
