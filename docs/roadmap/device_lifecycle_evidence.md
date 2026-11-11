---
title: The Infinity survives real-world lifecycle events
priority: P2
rank: f
executor: human
depends_on: []
specs: [docs/hardware]
---

## Outcome

Long holds, simultaneous Controls, hub reconnects, and logout/login behave
as the recorded HID fixtures predict on the physical device.

## Acceptance

- Human: perform each event with the Infinity attached through a hub.
- No stuck Action, lost or duplicated transition, or missed reconnect;
  results land in `docs/hardware`.
