# 0014: Manual Profiles with per-Device configuration

- **Status:** Accepted; supersedes Gate 0 answer 6A
- **Date:** 2026-07-31

## Context

The schema-2 envelope can contain multiple Profiles, but each Profile owns one
global Binding list and the UI exposes only Default. The user needs named work
modes such as Coding and Music, with independent setups for each connected
Device and immediate manual switching.

An attachment `DeviceID` is ephemeral. The Infinity 3 Driver does not yet
provide a trustworthy per-unit identifier, so identical units cannot honestly
receive different durable setups.

## Decision matrix

| Criterion                                       | Global Bindings | Per-Device-model setups | Per-attachment setups |
| ----------------------------------------------- | --------------: | ----------------------: | --------------------: |
| Supports different connected Device types       |               1 |                       5 |                     5 |
| Survives reconnect                              |               5 |                       5 |                     1 |
| Handles indistinguishable units honestly        |               2 |                       5 |                     2 |
| Supports future stable hardware identity        |               2 |                       5 |                     5 |
| Migrates current Infinity Bindings without loss |               5 |                       5 |                     2 |
| **Total**                                       |          **15** |                  **25** |                **15** |

## Decision

Advance `ProfileEnvelope` to schema 3. Each Profile owns ordered
`ProfileDeviceConfiguration` values. Each configuration has a typed
`DeviceModelID`, optional Driver-provided stable hardware identifier, and
independent Bindings.

Resolve an exact stable-unit setup first and its model-level setup second.
Infinity 3 uses the model-level setup. Identical units therefore share it until
the Driver can supply trustworthy stable identity.

Expose create, rename, duplicate, delete, edit, and Make Active flows. New
Profiles configure currently connected supported models with No Action.
Missing configurations remain inert. Inactive edits never affect runtime
behavior.

Profile activation is one ordered transaction:

1. validate and atomically persist the candidate envelope;
2. cancel every active Action on the Controller runtime's serial queue;
3. clear pressed ownership and install an immutable Binding resolver;
4. acknowledge runtime installation;
5. publish the new active Profile.

Schema-1 and schema-2 Profile identities, names, active selection, modes,
Actions, and shortcuts migrate into one Infinity 3 model-level setup per
Profile. Invalid input retains the existing corruption-recovery behavior.

## Consequences

- Coding, Music, and later work modes switch without reconnecting hardware.
- The input hot path performs only in-memory Device and Binding lookup.
- Profile persistence, UI, and switching never block a hardware callback.
- Device-specific facts remain at the Driver boundary.
- Automatic application-based switching remains deferred.
- A future Driver may add stable per-unit identity without another Profile
  schema redesign.
