# 0018: Exact keyboard Control fallback

- **Status:** Accepted
- **Date:** 2026-08-05
- **Amends:**
  [`0014_multi_profile_device_configuration.md`](0014_multi_profile_device_configuration.md)

## Context

A configured Action should remain usable when its physical Device is absent.
The fallback must preserve Momentary and Toggle semantics, avoid observing the
global keyboard stream, and surface shortcut conflicts instead of silently
failing. It must not duplicate Action configuration or make the domain depend
on the Infinity 3.

## Input mechanism matrix

| Criterion | Exact Carbon hot key | Global AppKit monitor | Core Graphics event tap |
| --- | ---: | ---: | ---: |
| Observes only configured chords | 5 | 1 | 1 |
| Delivers press and release | 5 | 5 | 5 |
| Reports reservation conflicts | 5 | 1 | 1 |
| Requires no new privacy permission | 5 | 2 | 1 |
| Avoids hot-path main-actor work | 5 | 4 | 4 |
| **Total** | **25** | **13** | **12** |

## Suggested shortcut matrix

| Criterion | Control–Shift–Command–D | Control–Command–D | Option–Command–D | Control–Option–Command–D |
| --- | ---: | ---: | ---: | ---: |
| Mnemonic for Dictation/default Control | 5 | 5 | 5 | 5 |
| Avoids documented macOS shortcuts | 5 | 1 | 1 | 5 |
| Avoids documented VoiceOver shortcuts | 5 | 5 | 5 | 1 |
| Distinct from ordinary typing | 5 | 5 | 5 | 5 |
| **Total** | **20** | **16** | **16** | **16** |

Control–Command–D invokes dictionary lookup, Option–Command–D shows or hides
the Dock, and VoiceOver uses Control–Option as its default modifier with
Command–D for the next different item. The recommendation is therefore
Control–Shift–Command–D (`⌃⇧⌘D`).

## Decision

- Add an optional activation shortcut to each Binding. It selects the existing
  Action and interaction mode; it does not contain duplicate Action data.
- Keep the fallback opt-in. Existing and new Profiles receive no implicit
  global registration. Offer `⌃⇧⌘D` as one-click suggested configuration.
- Register only active-Profile chords with `RegisterEventHotKey` on the
  application event target. Request exclusive delivery and consume only the
  registered press/release callbacks. Never install a global keyboard monitor
  or event tap.
- Timestamp the callback immediately, then resolve and dispatch it on the same
  serial Action queue as hardware input.
- Give physical and keyboard inputs one persistent Binding target. Momentary
  Actions begin for the first owner and end after the last owner releases;
  Toggle Actions advance on each distinct press from either source.
- Reject duplicate fallback chords within one Profile and chords matching any
  Keyboard Shortcut Action in that Profile. Require at least two modifiers so
  a fallback cannot capture ordinary typing or a common single-modifier chord.
  Publish a typed failure when macOS or another app prevents registration.
- Store the optional field in Profile schema 4. Schema 3 migrates without
  enabling any fallback.

## Consequences

- A configured Control works while its Device is disconnected.
- The privacy boundary remains narrow: the app receives configured exact hot
  keys, not global keystrokes.
- Active Profile changes, sleep, shutdown, and registration replacement release
  fallback ownership before unregistering chords.
- Another app may still reserve a chosen chord first; the Control editor names
  that failure and asks the user to record a different chord.

## Evidence

- Domain tests cover mixed-source Momentary ownership, Toggle changes, source
  cancellation, duplicate suppression, Profile conflicts, and migration.
- Runtime tests execute a fallback with no Device and publish its logical active
  state when a matching Device is connected.
- Source tests cover registration, press/release delivery, replacement cleanup,
  duplicate suppression, and typed registration failure.
