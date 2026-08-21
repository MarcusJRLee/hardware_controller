# 0004: Exclusive ownership of the supported VEC pedal

- **Status:** Accepted
- **Date:** 2026-07-26

## Context

The purchased VEC USB Footpedal was connected for the first physical-device
inspection. Its descriptor matches the implemented `05F3:00FF`,
Consumer/Programmable Buttons signature and exposes Button usages 1–3.

macOS attaches those elements to a relative-pointer service. With nonexclusive
access, the center Button-2 input produces a secondary click and the side
buttons remain available to the system as pointer buttons. Nonexclusive
observation therefore cannot meet the product promise that a configured
Control produces only its configured Action.

The first implementation also activated its `IOHIDManager` without opening it.
The app could match the Device and show **Ready**, but its IOHID client remained
closed and received no input values.

## Decision matrix

| Criterion | Nonexclusive observation | Exclusive ownership |
| --- | ---: | ---: |
| Receive physical Control events | Yes, when explicitly opened | Yes |
| Suppress macOS pointer clicks | No | Yes |
| Deterministic one-Control/one-Action behavior | No | Yes |
| Coexist with other pedal software simultaneously | Yes | No |
| Scope ownership to the exact supported Device | Yes | Yes |
| Automatic release after app exit | Yes | Yes |

## Decision

Hardware Controller will explicitly open the exact supported VEC Device with
`kIOHIDOptionsTypeSeizeDevice` before activating its HID manager.

- Exclusive ownership is limited to vendor `0x05F3`, product `0x00FF`, primary
  usage page `0x0C`, and primary usage `0x03`.
- Matching alone is not Ready. The app reports Ready only after exclusive open
  succeeds and the Device matches.
- Another app or Hardware Controller copy holding the Device produces an
  actionable unavailable state with Retry.
- Closing the input source closes and cancels the HID manager, releasing the
  Device back to macOS.
- Physical pressed state remains visible even when Accessibility prevents the
  configured Action from executing.

## Consequences

- macOS no longer receives pointer-button events from this pedal while Hardware
  Controller owns it.
- Other pedal applications cannot use the same Device simultaneously.
- A second Hardware Controller process cannot silently appear Ready.
- Quitting or crashing Hardware Controller releases OS-managed ownership.
- This decision does not authorize seizing keyboards, mice, unsupported HID
  collections, or a broader vendor/product match.

## Validation

On July 26, 2026, the connected purchased unit successfully opened with the
seize option. IORegistry reported `ClientOpened = Yes` and `ClientOptions = 1`.
A concurrent exclusive open returned `kIOReturnExclusiveAccess`; after the
owner exited, Retry acquired the Device and returned the UI to Ready.

Physical left/center/right actuation, simultaneous presses, and confirmation
that no pointer click escapes remain final hands-on acceptance checks.
