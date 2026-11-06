# Visual design, navigation, and icons

- **Status:** Accepted
- **Updated:** 2026-11-03
- **Replaces:** 0003, 0008, 0013, 0063, and the navigation part of 0030

## Context

The window mixes live hardware, Binding editing, Profiles, History, and
preferences. The connected controller should stay the visual center, and the
icons must say what each app is at 16 px. The current style is described in the
root [README](../../README.md) and [BRANDING](../../BRANDING.md).

| Criterion                       | Sidebar destinations | Separate windows | One scrolling workspace |
| ------------------------------- | -------------------- | ---------------- | ----------------------- |
| Keeps Controller device-centered| 🟢 Yes.              | 🟢 Yes.          | 🟠 Crowded. |
| Durable homes for Profiles and History | 🟢 Yes.       | 🟡 Scattered.    | 🔴 No. |
| One coherent window             | 🟢 Yes.              | 🔴 Several.      | 🟢 Yes. |
| Native macOS navigation         | 🟢 `NavigationSplitView`. | 🟡 Window menu. | 🟠 Custom. |

| Criterion                       | Center Signal (code-drawn) | Revised raster | System symbols |
| ------------------------------- | -------------------------- | -------------- | -------------- |
| Says what each app is           | 🟢 Pedals; a voice waveform. | 🟡 Depends on the art. | 🟡 Generic. |
| Legible at 16 px                | 🟢 Bold capsules.          | 🟠 Fine detail. | 🟢 Yes. |
| Reproducible and reviewable     | 🟢 One Swift script.       | 🔴 Opaque binary. | 🟢 Yes. |

## Decision

**Direction**

- Device-centered studio utility: the connected controller is the visual
  center, live state appears on its Controls, and configuration sits directly
  below. Native materials, controls, typography, and accessibility stay intact.
- Native title bar with standard window controls; content starts below it.
- The Device stage keeps a fixed layout; a press animates only the Control
  (160 ms spring, removed with Reduce Motion).
- Device-specific layout is presentation metadata, never a domain dependency.

**Navigation**

- One AppKit-owned window with a `NavigationSplitView` and four destinations:

| Destination | Owns |
| ----------- | ---- |
| Controller  | Live Devices, active-Profile Bindings, permissions, Dictation testing. |
| Profiles    | Profile lifecycle, activation, per-Device setup. |
| History     | Voice sessions, search, correction, re-delivery, export ([voice_history](voice_history.md)). |
| General     | Appearance, microphone, Launch at Login, retention. |

- The sidebar starts expanded with the native collapse control. Launch and Dock
  reopen select Controller; Settings and ⌘, select General. Menu-bar commands
  route this window rather than open new ones.

**Icons**

- `tools/app_icons/render_app_icons.swift` draws both icons with CoreGraphics:
  a graphite tile with rounded capsules, amber only on the center element.
  Hardware Controller shows three pedals from above; Voice Input shows a
  five-bar waveform. macOS gets its own continuous-corner tile and shadow on
  Apple's 824-point grid; iOS is full-bleed for the system mask.
- Icons use no manufacturer wordmark or photograph.

## Consequences

- Regenerate icons with `swift tools/app_icons/render_app_icons.swift`; the
  PNGs are committed outputs.
- A future controller replaces the pedal stage while reusing configuration,
  permission, and status components.
- Window checks cover sidebar visibility, routing, ⌘,, keyboard navigation, and
  every appearance and accessibility mode.
