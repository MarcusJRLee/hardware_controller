# Decision 0057: Single Rust retention policy

**Status:** Accepted; completes the migration planned in
[0035](0035_portable_voice_c_abi.md)

## Context

History audio expiry was implemented twice: a Swift planner used by both apps
and a Rust planner exported through `voice_retention_plan_v1` but used only by
tests. One CUJ fixture kept them equal. Every policy change had to be made twice,
and a case the fixture did not cover could drift silently.

| Criterion | Rust policy through the C ABI | Keep both with fixture parity | Swift only |
| --- | --- | --- | --- |
| Implementations to change | One | Two | One |
| Drift risk | None | Bounded by fixture coverage | None, but no Android path |
| Platform line of sight | macOS, iOS, Android, Windows, Linux | Same | Apple only |
| Decision | Selected | Retired | Rejected |

## Decision

- Delete the Swift planner. Keep the Swift value types and settings validation
  in `HardwareControllerCore`.
- `RustVoiceHistoryRetentionPlanner` in `HardwareControllerVoiceFFI` maps the
  Swift values to the V1 ABI, rounds times down to Unix milliseconds, and maps
  every status and expiration reason exhaustively. Unknown values fail as
  `portablePolicyFailure`.
- The macOS SQLite retention store and the iOS History repository call it.
- The iOS target that compiles shared Core sources is named
  `HardwareControllerCore`, so shared adapters import one module name on both
  platforms.

## Consequences

- The Rust planner also rejects duplicate session identifiers and
  unrepresentable timestamps, which the Swift planner accepted. Both apps pass
  unique database identifiers, so no stored History changes.
- The CUJ fixture now tests the linked boundary instead of comparing two copies.
