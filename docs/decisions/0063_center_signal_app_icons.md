# 0063: Replace Signal Bridge with the Center Signal icon family

- **Status:** Accepted
- **Date:** 2026-11-02
- **Supersedes:** the provisional icon in [0025](0025_public_source_publication.md)

## Context

Signal Bridge was provisional. The owner judged it and its iOS crop poor: the
glossy raster did not read at small sizes, and the nodes did not say "pedal" or
"voice".

## Decision matrix

| Criterion | Center Signal (code-drawn) | Revised raster | System symbols |
| --- | --- | --- | --- |
| Says what each app is | 🟢 Pedals; a voice waveform. | 🟡 Depends on the art. | 🟡 Generic. |
| Legible at 16 px | 🟢 Three or five bold capsules. | 🟠 Gloss and fine detail. | 🟢 Yes. |
| Reproducible and reviewable | 🟢 One Swift script, no tools. | 🔴 Opaque binary. | 🟢 Yes. |
| Matches the style (amber = active) | 🟢 Only the center is amber. | 🟡 Varies. | 🟠 No identity. |

## Decision

`tools/app_icons/render_app_icons.swift` draws both icons with CoreGraphics on a
graphite tile with rounded capsules. Hardware Controller shows three pedals from
above with the center pedal amber. Voice Input shows a five-bar waveform with
the center bar amber. macOS gets its own continuous-corner tile and shadow on
Apple's 824-point grid; iOS is full-bleed for the system mask.

## Consequences

- Regenerate with `swift tools/app_icons/render_app_icons.swift`; the PNGs are
  committed outputs.
- BRANDING and the README style section name Center Signal.
