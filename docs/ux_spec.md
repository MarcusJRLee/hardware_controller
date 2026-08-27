# UX specification

**Status:** current accepted visual and interaction direction.

## Experience character

The app should feel calm, tactile, and precise: closer to a well-made studio
utility than a generic settings form. Most of the time it is invisible. When
opened, it should answer three questions immediately:

1. Is my Device connected and ready?
2. What will each physical Control do?
3. Is an Action active right now?

History, Profiles, and General answer secondary questions without crowding
Controller: what was captured, which work mode is active, and where application
preferences live.

Color is reserved for active state, required attention, and errors. Typography,
spacing, motion, and control position carry the rest of the hierarchy.

## Surfaces

### Dock, application menu, and menu bar

The app uses the regular foreground activation policy. It remains visible in
the Dock while running, and selecting it makes the top-left application menu
read **Hardware Controller**. The menu-bar item remains the compact runtime
surface.

| State             | Required communication                                            |
| ----------------- | ----------------------------------------------------------------- |
| Ready             | Quiet monochrome pedal icon; accessible label names the active Profile. |
| Disconnected      | Subtle disconnected treatment without repeated notifications.     |
| Permission needed | Attention marker and a concise recovery item.                     |
| Dictation active  | Immediate but non-distracting active treatment.                   |
| Error             | Persistent marker until the state is understood or resolved.      |

The menu contains Device status, an active Profile picker, Controller, History,
Profiles, Settings, launch-at-login state, and Quit. It does not duplicate the
complete application window.

### Application window

One native sidebar contains exactly Controller, History, Profiles, and General. It opens
expanded, collapses through the native toolbar control, and remembers only its
visibility. Manual launch opens Controller; Settings and Command–Comma open
General in the same window.

Controller uses one Device card with:

- Device name and connection state;
- a driver-supplied control layout;
- a prominent center Control and visually secondary left/right Controls;
- each Control's Action and interaction mode;
- an optional exact keyboard fallback for each configured Action;
- immediate physical press feedback;
- a single path into permissions and diagnostics.

Selecting a Control opens its configuration without navigating away from Device
context. A generic list is available for assistive technology and Devices whose
layout metadata is absent.

History uses a searchable session list and selected-result evidence view. It
keeps prior results immutable, makes correction and stage reruns explicit, and
uses one delayed action for safe re-delivery to a fresh target. Destructive
deletion is visually distinct from reuse actions. When audio expires, the
playback card names the applicable age, size, count, or low-disk rule while
leaving transcript evidence available.

The list header exposes one labeled import action beside quiet refresh. Import
uses the native audio open panel and shows one shared progress state while local
ASR, formatting, app-owned CAF finalization, and History commit run. The new
row is selected and labeled **Imported recording**; transcript-only and
audio-only outcomes use explicit non-error notices and keep recovery actions
available.

Profiles uses a stable Profile list and selected-Profile editor. Active state
is separate from selection. General uses native form sections for Appearance,
the Local Dictation microphone, Local AI Dictation, Voice History storage, and
Launch at Login. Voice History storage uses independent preset pickers for age,
bytes, and audio count with explicit `Unlimited` and no-retained-audio choices.
Local AI progressively reveals provider-specific model retention controls while
keeping dictionary, context, instructions, readiness, and provider test in one
restrained section.

The window remembers size within a supported range, never requires horizontal
scrolling, and uses native materials sparingly. It should not imitate the
physical pedal with photorealistic skeuomorphism.
The standard macOS window controls sit in a distinct native title bar. App
content begins below the title bar and never renders behind those controls.

### First run and permissions

First run is progressive:

1. Connect a supported Device.
2. Press each Control to verify identification.
3. Explain Accessibility only when an assigned Action requires it.
4. Request Microphone access for either Dictation Action and Speech Recognition
   on macOS 15–25.
5. Offer launch at login.
6. Run a focused-text-field Local Dictation test.

Each permission page states what the capability allows, what still works
without it, and how to change it later. The app never implies it granted a
system permission itself.

## Configuration behavior

- Center defaults to Local Dictation and Momentary.
- Left and right default to No Action but remain equally editable.
- Interaction mode copy is `Hold` and `Toggle`; technical docs use `Momentary`
  and `Toggle`.
- Keyboard Shortcut capture clearly shows modifier press/release and provides
  Cancel and Clear without trapping input.
- Unsupported interaction modes are absent or disabled with a specific reason.
- Rebinding a currently active Control requires it to be released first or
  invokes explicit cleanup.
- Keyboard fallback is opt-in. An unset Binding offers **Use suggested
  ⌃⇧⌘D**; a set Binding supports exact recording and **Clear**.
- Inactive Profiles explain that their fallback becomes available on
  activation. Active reservation failures request a different chord in place.
- Changes save immediately after validation; a brief undo is preferred over a
  modal confirmation.
- Local AI Dictation is a separate Action row, never a Local Dictation mode.
- Every Action row and Control card shows a valid platform icon; Local AI
  Dictation remains visually distinct from Local Dictation.
- Local AI formatting is automatic; do not expose Clean/Structured controls.
- The Local AI provider test reports readiness without starting the microphone
  or reading a target.
- Personal dictionary inputs use visible field chrome. Add remains unavailable
  until every required trimmed value is present, and Return submits a complete
  entry.
- Recommended and validated Ollama models are labeled in the model picker;
  unvalidated installed models remain explicit.

## State feedback

| Event              | Feedback                                                             |
| ------------------ | -------------------------------------------------------------------- |
| Physical press     | Control compresses/highlights on the next display frame.             |
| Physical release   | Highlight clears on the next display frame.                          |
| Action begin       | Action label and menu bar enter active state.                        |
| Action end         | Active state clears only after the executor accepts the end.         |
| Listening/finalize | Dedicated status shows authoritative phase, target app, and text.     |
| AI refinement      | Dedicated status distinguishes preparing, refining, validating, delivering, deterministic Edited fallback, and failure. |
| Focus failure      | Automatic insertion stops and recoverable final text can be copied.   |
| Microphone change  | Active Dictation ends and prepared capture uses the new app route.     |
| Device unplug      | Layout remains visible, becomes unavailable, and explains reconnect. |
| Permission denial  | Binding remains configured but shows why execution is blocked.       |
| Unsupported Device | Show identity and support status; do not show fake Bindings.         |

UI feedback mirrors authoritative domain state. Animation never delays Action
dispatch and never pretends an Action succeeded. A typed asynchronous
Dictation failure uses only the dedicated transcription card; it does not add
a second generic dispatch card or move the Device layout.

### Working-app transcript HUD

- Do not show idle, readiness, completion, or failure badges beside the pointer
  or caret.
- A live-capable target shows provisional text inline and no HUD.
- A final-only or buffered-event target shows a click-through HUD only after
  nonempty transcript text exists and only until completion or failure.
- Local AI Dictation always uses the provisional HUD and never inserts model
  output before validation completes.
- Prefer the text caret as the anchor. If caret bounds are unavailable, use one
  stable screen-edge location and never follow the pointer.
- Failure detail and **Copy Text** recovery remain in Controller and the menu-bar
  attention state.

## Accessibility

- Every visual Control has a stable accessibility label, value, role, and
  pressed/active state.
- All configuration is operable by keyboard without relying on the physical
  Device.
- Focus order follows the physical layout, then details and recovery actions.
- Status never relies on color alone.
- Increased contrast replaces translucent or low-separation treatments.
- Reduced motion removes spring/compression transitions but preserves state
  changes.
- Large text reflows labels rather than truncating Action names.
- VoiceOver copy distinguishes the physical Control state from the Action state.

## Visual review outcome

The user delegated the finished visual choice without another approval pause.
The device-centered studio utility direction was selected and recorded in
[`decisions/0003_visual_direction.md`](decisions/0003_visual_direction.md).

The device-centered shell keeps all three Bindings visible, preserves a focused
Dictation test field, and uses the same configuration order for pointer,
keyboard, and assistive technology. Every UI change must be reviewed in light,
dark, increased-contrast, reduced-motion, keyboard-only, VoiceOver, and
large-text conditions before its release scope is accepted.
