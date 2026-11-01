# UX specification

Direction: a calm, device-centered studio utility
([0003](decisions/0003_visual_direction.md)). Opened, the app answers three
questions at once: is my Device ready, what does each Control do, and is an
Action active? Color marks only active state, attention, and errors;
typography, spacing, and position carry everything else.

## Surfaces

| Surface | Contract |
| --- | --- |
| Dock and app menu | Regular foreground app named **Hardware Controller**. Manual launch opens Controller; login-item launch stays quiet. |
| Menu bar | Monochrome pedal icon. Lists Device status, active Profile picker, **Record Voice**, each destination, Launch at Login, Quit. Record never activates the window, so the target app keeps focus. |
| Window | Native sidebar with exactly Controller, History, Profiles, General; opens expanded; content starts below the title bar; no horizontal scrolling. |
| Controller | One Device card with Driver-supplied layout, a prominent center Control, each Control's Action, mode, and optional fallback, and immediate press feedback. Selecting a Control edits it in place. |
| History | Searchable session list plus evidence detail. Prior results are immutable; reruns and re-delivery are explicit; delete is visually distinct. Expired audio names its rule. |
| Profiles | Stable list and editor; active state is separate from selection. |
| General | Native form sections: Appearance, microphone, Local AI, Voice chord, History storage, Launch at Login. |
| Transcript HUD | Click-through, nonactivating; only while a target cannot show live text and text exists; anchored to the caret or one stable edge, never the pointer. |

## Behavior

- Center defaults to Local Dictation and Hold; left and right to No Action.
- Copy says **Hold** and **Toggle**; technical docs say Momentary and Toggle.
- Shortcut recording shows modifiers live and offers Cancel and Clear.
- Fallbacks are opt-in (**Use suggested ⌃⇧⌘D**); conflicts ask for another
  chord in place.
- Changes save immediately after validation.
- Local AI Dictation is its own Action, never a mode of Local Dictation; there
  is no Clean/Structured toggle.
- The provider test never starts the microphone or reads a field.

## State feedback

| Event | Feedback |
| --- | --- |
| Press / release | Control highlights and clears on the next frame. |
| Action begin / end | Active state appears; clears only after the executor accepts the end. |
| Dictation phases | One status card: Preparing, Listening, Finalizing, Refining, Validating, Delivering, fallback, failure. |
| Focus change | Insertion stops; recoverable text offers **Copy Text**. |
| Unplug | Layout stays, marked unavailable, with reconnect guidance. |
| Permission denied | Binding stays configured and says why it is blocked. |
| Unsupported Device | Identity and support status; no fake Bindings. |

A Dictation failure appears once, in its card, without moving the layout.
Animation never delays dispatch or implies success.

## Accessibility

- Every Control has a stable label, value, role, and pressed/active state;
  VoiceOver distinguishes physical state from Action state.
- Everything works by keyboard; focus follows the physical layout.
- Status never relies on color alone; increased contrast removes translucency.
- Reduced motion removes transitions but keeps state changes.
- Large text reflows instead of truncating.

Review every UI change in light, dark, increased contrast, reduced motion,
keyboard-only, VoiceOver, and large text before it ships.
