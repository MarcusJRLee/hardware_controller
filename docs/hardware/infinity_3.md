# VEC Infinity 3 USB Foot Pedal

**Support status:** the purchased unit's identity, descriptor, elements,
exclusive-open behavior, three-Control mapping, simultaneous combinations, and
installed-app Dictation are confirmed. Lifecycle and connection-path evidence
remains deferred.

## Identity

| Field | Implemented signature |
| --- | --- |
| Product | Infinity USB-3 / IN-USB-3 three-pedal control |
| Manufacturer | VEC Electronics Corporation / PI Engineering USB identity |
| Connection | USB HID |
| Vendor ID | `0x05F3` |
| Product ID | `0x00FF` |
| Primary usage page | Consumer, `0x0C` |
| Primary usage | Programmable Buttons, `0x03` |
| Input elements | Button page usages 1, 2, and 3 |
| Raw input report | 2 bytes; low three bits are left, center, and right |

[VEC's product page](https://www.veccorp.com/foot-controls.html) identifies the
Infinity USB-3 as its digital three-control USB product but does not publish the
protocol.

The narrow signature and report hypothesis are corroborated by:

- the maintained
  [`peternewman/VECFootpedal`](https://github.com/peternewman/VECFootpedal)
  driver, which supports the VEC USB identity and multiple devices;
- the independent archived
  [`breedx2/infinity-footpedal`](https://github.com/breedx2/infinity-footpedal)
  userspace implementation;
- a December 2025
  [IN-USB-3 descriptor capture](https://forum.remapper.org/t/emulate-a-3-button-foot-pedal-using-keyboard-or-mouse-button/190)
  showing the exact Consumer/Programmable Buttons collection, Button usages
  1–3, two-byte input length, and `05F3:00FF` identity;
- the public USB ID database entry for `05f3:00ff` as VEC Footpedal.

These independent public observations predated and now agree with the
purchased-unit capture below.

## Purchased-unit capture

Captured on July 26, 2026 on macOS 26.5.2:

| Field | Observed value |
| --- | --- |
| Product / manufacturer | `VEC USB Footpedal` / `VEC` |
| USB identity | `05F3:00FF`, device version `0x0120` |
| Primary collection | Consumer `0x0C`, Programmable Buttons `0x03` |
| Input elements | Button page `0x09`, usages 1, 2, and 3 |
| Maximum input report | 2 bytes |
| Polling interval | 8 ms |
| Report descriptor | `050c0903a101a1020508094b750895239102c0a10205091901290315002501950375018102950175058101950175088101c0c0` |

IORegistry showed that macOS builds a `RelativePointer` from the three Button
elements. That directly explains the center pedal's default secondary click.
An explicit exclusive open succeeded; a concurrent exclusive open returned
`kIOReturnExclusiveAccess`.

A July 29 recapture corrected one transcribed descriptor nibble in this record:
the first constant padding field is five bits, not eight. The corrected
descriptor is internally consistent with three Button bits plus thirteen
constant bits in the confirmed two-byte report. Identity, version, collection,
and element mapping were unchanged.

A July 30 actuation capture confirmed usage 1 as left, usage 2 as center, and
usage 3 as right. It recorded independent presses, approximately five-second
holds, every simultaneous pair, all three Controls, and all releases. The
sanitized reports are stored in
`Tests/HardwareControllerCoreTests/fixtures/infinity_3_physical_capture.swift`
and replayed by the driver tests.

## Live driver behavior

The macOS driver:

- uses `IOHIDManager` with exact vendor, product, primary usage page, and
  primary usage matching;
- explicitly opens that exact collection with
  `kIOHIDOptionsTypeSeizeDevice` before activation;
- reports exclusive-access and permission failures instead of treating a
  matched but unopened Device as Ready;
- schedules matching, removal, and input callbacks on the same
  user-interactive serial queue as normalization and action dispatch;
- maps Button usage 1 to `left`, 2 to `center`, and 3 to `right`;
- uses each `IOHIDValue` timestamp as the start of measured dispatch latency;
- relies on the binding engine to suppress duplicate logical transitions;
- ends active Actions before publishing device removal.

The included raw-report decoder validates a two-byte state report and maps bits
`0x01`, `0x02`, and `0x04` to the same logical Controls. Its tests cover center
press/hold/release, simultaneous changes, and malformed lengths. The live
macOS path uses typed HID elements rather than indexing raw report bytes. One
`Infinity3ButtonMapping` value defines the raw mask, HID usage, and Control
descriptor for each position so those paths cannot drift independently.

## Logical Controls

| Logical ID | Physical position | First-release default |
| --- | --- | --- |
| `left` | Left foot control | No Action |
| `center` | Wide center foot control | Local Dictation, Hold |
| `right` | Right foot control | No Action |

These identifiers are driver output. The domain, Binding, Profile, Action, and
settings components do not inspect HID bytes or vendor identifiers.

## Remaining physical evidence

The connected unit confirms the product string, USB identity, descriptor,
collection, Button elements, report size, polling interval, exclusive-open
behavior, physical ordering, and simultaneous combinations. These rows remain:

- dedicated ten-second holds and pointer-click passthrough observation;
- disconnect while active and reconnect behavior;
- attach/detach behavior through the intended hub or adapter;
- behavior across sleep/wake and login;
- whether another VEC firmware shares the identity but changes the collection.

The app will ignore a device whose primary collection differs from the
implemented signature. It must not broaden matching to make an unknown device
appear supported.

## Physical confirmation checklist

1. Install and open the signed app using the [user guide](../user_guide.md).
2. Connect the pedal and confirm the header changes to **Ready** within one
   second.
3. Press left, center, and right independently; confirm the matching rendered
   pedal compresses and releases once.
4. Hold each pedal for ten seconds; confirm no repeated Action begins.
5. Press every pair and all three together; confirm every visual Control tracks
   independently.
6. Set side pedals to harmless test shortcuts and confirm one output per press.
7. Test center Local Dictation in Hold and Toggle modes in TextEdit and the
   intended daily target app; verify Preparing, Listening, and Finalizing.
8. Unplug while Hold Dictation is active, then repeat while Toggle Dictation is
   active.
9. Reconnect without restarting the app and confirm the saved Bindings return.
10. Repeat through the intended hub or adapter, after sleep/wake, and after a
    logout/login with Launch at Login enabled.
11. Confirm no press produces a primary, secondary, or middle click while
    Hardware Controller displays Ready.

Sanitized captures should be committed as deterministic driver fixtures with a
short manifest naming the gesture, expected transitions, macOS version, and
capture tool.

Quit the installed app before running the test-only physical capture:

```sh
HC_CAPTURE_INFINITY_3_REPORTS=1 \
HC_CAPTURE_DURATION_SECONDS=45 \
  swift test --filter capturesPhysicalReportsAndTypedValues
```

The harness exclusively opens only the exact supported signature and records
relative monotonic timestamps, two-byte reports, Button usages, and values. It
does not record registry identifiers, serial numbers, audio, or application
content. Ordinary test runs skip it.

## Driver acceptance

- Match only the confirmed device signature.
- Emit one press and one release per physical actuation.
- Preserve valid simultaneous Controls.
- Keep timestamps monotonic and dispatch off the main actor.
- Clean up active state on removal, permission loss, Profile change, and
  shutdown.
- Reject malformed reports and unknown collection signatures safely.
- Exclusively own only the exact supported VEC collection while running.
- Add no Infinity-specific condition to the domain, Action, Profile, or generic
  input-source boundary.

## References

- [VEC Infinity USB-3 product page](https://www.veccorp.com/foot-controls.html)
- [Apple IOHIDManager documentation](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [USB-IF HID specifications and usage tables](https://www.usb.org/hid)
- [peternewman/VECFootpedal](https://github.com/peternewman/VECFootpedal)
- [breedx2/infinity-footpedal](https://github.com/breedx2/infinity-footpedal)
- [IN-USB-3 descriptor capture](https://forum.remapper.org/t/emulate-a-3-button-foot-pedal-using-keyboard-or-mouse-button/190)
