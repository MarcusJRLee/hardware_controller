# 0013: Three-destination application navigation

- **Status:** Superseded by [0030](0030_voice_history_workspace.md)
- **Date:** 2026-07-31

## Context

The device-centered Controller workspace mixed live hardware, Binding editing,
permissions, Dictation testing, and application preferences in one long view.
Multi-Profile management needs a durable home without hiding the live
Controller or making appearance difficult to find.

## Decision matrix

| Criterion                            | Three-destination sidebar | Separate Controller and Settings windows | Single scrolling workspace |
| ------------------------------------ | ------------------------: | ---------------------------------------: | -------------------------: |
| Keeps Controller device-centered     |                         5 |                                        5 |                          2 |
| Makes Profiles durable               |                         5 |                                        3 |                          1 |
| Makes General discoverable           |                         5 |                                        5 |                          2 |
| Preserves one coherent window        |                         5 |                                        2 |                          5 |
| Scales to later destinations         |                         5 |                                        3 |                          1 |
| Uses native macOS navigation         |                         5 |                                        3 |                          2 |
| **Total**                            |                    **30** |                                   **21** |                     **13** |

## Decision

Use one AppKit-owned application window containing a native SwiftUI
`NavigationSplitView` with exactly three destinations:

| Destination | Authority |
| ----------- | --------- |
| Controller  | Live Devices, active-Profile Bindings, permissions, and Dictation testing. |
| Profiles    | Profile lifecycle, activation, and per-Device setup. |
| General     | Appearance and Launch at Login. |

The sidebar starts expanded and uses the native collapse control. Persist its
visibility separately from Profiles. Manual launch and Dock reopen select
Controller. Settings and Command–Comma select General. Menu-bar commands route
the same window instead of creating destination-specific windows.

Keep the accepted device-centered studio direction inside Controller. Profiles
and General use restrained native lists, forms, spacing, and typography.

## Consequences

- General preferences remain easy to find without displacing the primary
  Controller workflow.
- Profiles is a stable destination, while Profile names remain data rather
  than navigation destinations.
- The application needs small navigation and preference models separate from
  hardware state.
- Window verification expands to sidebar visibility, destination routing,
  Command–Comma, keyboard navigation, and all appearance/accessibility modes.
