# 0008: Infinity 3 iconography

- **Status:** Accepted
- **Date:** 2026-07-27
- **Superseded by:**
  [`0025_public_source_publication.md`](0025_public_source_publication.md)
- **Amends:**
  [`0003_visual_direction.md`](0003_visual_direction.md)

## Context

The version 1.2 menu-bar item used the generic `switch.2` SF Symbol and the app
icon resembled three separate upright switches. Neither communicated the
physical controller the app currently supports.

The Infinity 3's recognizable form is one low, flared housing with a broad
center control, narrow side controls, long dividing seams, and a cable exiting
the back. The product boundary still requires hardware-specific behavior to
stop at the Driver and presentation metadata boundaries.

## Decision matrix

| Direction | Recognizable at Dock size | Legible at menu-bar size | Domain coupling |
| --- | ---: | ---: | ---: |
| Generic switches | Low | High | None |
| Photographic product image | High | Low | None |
| Simplified Infinity 3 silhouette | High | High | Presentation only |

## Decision

- Use an original simplified Infinity 3 silhouette for the app and menu-bar
  icons.
- The app icon uses the accepted near-black and mint visual system, a broad
  center surface, narrow side controls, flared housing, and a restrained cable
  cue.
- The menu-bar icon is a monochrome template derived from the same geometry.
  Its active variant fills the broad center control.
- Do not reproduce the VEC wordmark or embed a manufacturer photograph.
- Keep icon code and packaging assets outside the domain, Binding, Action, and
  Driver behavior.

## Consequences

- The running app and installed artifact communicate the physical workflow at
  a glance.
- A future supported Device does not require a domain migration. A later
  product-brand decision may supersede this presentation choice.
