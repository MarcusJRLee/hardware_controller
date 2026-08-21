# 0003: Device-centered studio utility

- **Status:** Accepted
- **Date:** 2026-07-24

## Context

The user requested a finished, pixel-polished product without another approval
pause. The UX specification defined three possible directions: a
device-centered studio utility, a restrained native inspector, and a spatial
control canvas.

## Decision

Use the device-centered studio utility.

- The connected controller is the visual center of the window.
- Live physical and active state appears directly on its Controls.
- Configuration remains visible immediately below the Device instead of hiding
  behind navigation.
- Near-black hardware rendering contrasts with the native window in both
  appearances.
- Mint communicates ready/active state; blue is reserved for demonstration;
  amber communicates required attention.
- Native materials, controls, typography, and accessibility behavior remain
  intact beneath the custom composition.

## Visual tokens

| Token | Value |
| --- | --- |
| Accent | RGB 46, 209, 171 |
| Active secondary | RGB 64, 168, 250 |
| Attention | RGB 250, 163, 61 |
| Card radius | 20 pt |
| Compact radius | 13 pt |
| Main content width | 980 pt maximum |
| Window minimum | 820 × 660 pt |
| Pedal press response | 160 ms spring; removed with Reduce Motion |

## Consequences

- Device-specific layout metadata remains a presentation input rather than a
  domain dependency.
- The center Control receives additional border emphasis without reducing
  left/right configurability.
- The UI is not photorealistic; physical depth exists only to make live state
  legible.
- A future controller can replace the pedal stage while reusing configuration,
  permission, system setup, and status components.

## Amendment: native window framing

**Date:** 2026-07-30

Keep the standard macOS window controls inside a distinct native title bar.
Application content begins below the title bar so the window has a deliberate
top boundary in every appearance.
